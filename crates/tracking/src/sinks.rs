//! Tracking for other apps on this computer or the network (tracker/src/yorishiro_tracker/sinks/): the VTube
//! Studio iPhone protocol (VTube Studio, OpenVT and others take it as a phone's tracking) and iFacialMocap
//! (VSeeFace, Warudo, VNyan). Both send the finished frame (after the neutral and smoothing), unmirrored.

use crate::frame::{FaceFrame, ARKIT52};
use std::collections::HashMap;
use std::net::{SocketAddr, UdpSocket};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Python's round(x, n) for printing: half to even on the scaled value
fn round_to(x: f64, digits: i32) -> f64 {
    let s = 10f64.powi(digits);
    (x * s).round_ties_even() / s
}

fn json_number(x: f64) -> String {
    if x == x.trunc() && x.abs() < 1e15 { format!("{x:.1}") } else { format!("{x}") }
}

/// VTube Studio iPhone protocol (DenchiSoft/VTubeStudioBlendshapeUDPReceiverTest): a receiver asks on
/// UDP 21412 with {"messageType": "iOSTrackingDataRequest", "time": seconds, "ports": [...]}, then gets one
/// JSON object per frame on each port until the time runs out.
pub struct VtsIphoneSink {
    socket: UdpSocket,
    clients: HashMap<SocketAddr, Instant>,
    /// signs of the rotation's x (turn), y (nod), z (tilt), for receivers that read them the other way
    pub sign: [f64; 3],
}

pub const VTS_REQUEST_PORT: u16 = 21412;
const VTS_MAX_SECONDS: f64 = 10.0;

impl VtsIphoneSink {
    pub fn open(port: u16) -> std::io::Result<Self> {
        let socket = UdpSocket::bind(("0.0.0.0", port))?;
        socket.set_nonblocking(true)?;
        Ok(Self { socket, clients: HashMap::new(), sign: [1.0; 3] })
    }

    /// Requests waiting on the socket: who wants frames, on which ports, for how long.
    fn poll_requests(&mut self) {
        let mut buf = [0u8; 4096];
        while let Ok((n, from)) = self.socket.recv_from(&mut buf) {
            let text = String::from_utf8_lossy(&buf[..n]);
            if !text.contains("iOSTrackingDataRequest") {
                continue;
            }
            // tiny ad hoc reads, the request is small and flat
            let number = |key: &str| -> Option<f64> {
                let at = text.find(&format!("\"{key}\""))? + key.len() + 2;
                let rest = text[at..].trim_start().strip_prefix(':')?.trim_start();
                let end = rest.find(|c: char| !(c.is_ascii_digit() || c == '.' || c == '-')).unwrap_or(rest.len());
                rest[..end].parse().ok()
            };
            // the reference names it "time", OpenVT sends "sendForSeconds"
            let seconds = number("time").or_else(|| number("sendForSeconds")).unwrap_or(VTS_MAX_SECONDS).clamp(0.5, VTS_MAX_SECONDS);
            let ports: Vec<u16> = text.find("\"ports\"")
                .and_then(|at| {
                    let rest = &text[at..];
                    let (a, b) = (rest.find('[')?, rest.find(']')?);
                    Some(rest[a + 1..b].split(',').filter_map(|p| p.trim().parse::<u16>().ok()).filter(|&p| p > 0).take(32).collect())
                })
                .unwrap_or_default();
            for port in ports {
                self.clients.insert(SocketAddr::new(from.ip(), port), Instant::now() + Duration::from_secs_f64(seconds));
            }
        }
    }

    /// One frame's JSON, None when no face was found.
    pub fn payload(&self, frame: Option<&FaceFrame>) -> String {
        let ms = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0);
        let Some(f) = frame else {
            return format!("{{\"Timestamp\":{ms},\"Hotkey\":-1,\"FaceFound\":false}}");
        };
        let vec = |x: f64, y: f64, z: f64| {
            format!("{{\"x\":{},\"y\":{},\"z\":{}}}", json_number(round_to(x, 3)), json_number(round_to(y, 3)), json_number(round_to(z, 3)))
        };
        let d = f.head_rotation.map(f64::to_degrees); // yaw, pitch, roll
        let t = f.head_translation.map(|v| v * 100.0); // cm
        let eye = |e: [f64; 3]| vec(e[1].to_degrees(), e[0].to_degrees(), 0.0);
        let shapes: Vec<String> = ARKIT52.iter().zip(f.blendshapes).map(|(n, v)| {
            let mut name = n.to_string();
            name[..1].make_ascii_uppercase();
            format!("{{\"k\":\"{name}\",\"v\":{}}}", json_number(round_to(v, 4)))
        }).collect();
        format!(
            "{{\"Timestamp\":{ms},\"Hotkey\":-1,\"FaceFound\":true,\"Rotation\":{},\"Position\":{},\"EyeLeft\":{},\"EyeRight\":{},\"BlendShapes\":[{}]}}",
            vec(self.sign[0] * d[0], self.sign[1] * d[1], self.sign[2] * d[2]), vec(t[0], t[1], t[2]),
            eye(f.left_eye_rotation), eye(f.right_eye_rotation), shapes.join(",")
        )
    }

    /// The new requests, then this frame to everyone still asking. Returns how many receivers got it.
    pub fn send(&mut self, frame: Option<&FaceFrame>) -> usize {
        self.poll_requests();
        let now = Instant::now();
        self.clients.retain(|_, until| *until > now);
        if self.clients.is_empty() {
            return 0;
        }
        let data = self.payload(frame);
        self.clients.keys().filter(|c| self.socket.send_to(data.as_bytes(), c).is_ok()).count()
    }
}

/// iFacialMocap text, one datagram per frame straight to HOST:49983 (a receiver on the same computer holds
/// that port itself, so there is no handshake): name-value pairs 0..100 with _L/_R names, then head rotation
/// (nod, turn, tilt) and position in cm, then each eye.
pub struct IFacialMocapSink {
    socket: UdpSocket,
    to: SocketAddr,
    /// signs of rx (nod), ry (turn), rz (tilt)
    pub sign: [f64; 3],
}

pub const IFACIALMOCAP_PORT: u16 = 49983;

impl IFacialMocapSink {
    pub fn open(host: &str) -> std::io::Result<Self> {
        use std::net::ToSocketAddrs;
        let to = (host, IFACIALMOCAP_PORT).to_socket_addrs()?.next()
            .ok_or_else(|| std::io::Error::other(format!("cannot resolve {host}")))?;
        Ok(Self { socket: UdpSocket::bind(("0.0.0.0", 0))?, to, sign: [1.0; 3] })
    }

    pub fn payload(&self, f: &FaceFrame) -> String {
        let shapes: Vec<String> = ARKIT52.iter().zip(f.blendshapes).map(|(n, v)| {
            let name = n.replace("Left", "_L").replace("Right", "_R");
            format!("{name}-{}", (v.clamp(0.0, 1.0) * 100.0).round_ties_even() as i64)
        }).collect();
        let [yaw, pitch, roll] = f.head_rotation.map(f64::to_degrees);
        let head = [self.sign[0] * pitch, self.sign[1] * yaw, self.sign[2] * roll];
        let pos = f.head_translation.map(|v| v * 100.0);
        let nums: Vec<String> = head.iter().chain(pos.iter()).map(|v| format!("{v:.2}")).collect();
        let eye = |e: [f64; 3]| format!("{:.2},{:.2},0.00", e[1].to_degrees(), e[0].to_degrees());
        format!("{}|=head#{}|rightEye#{}|leftEye#{}|", shapes.join("|"), nums.join(","), eye(f.right_eye_rotation), eye(f.left_eye_rotation))
    }

    /// Nothing without a face: receivers keep the last pose, as when the phone loses the face.
    pub fn send(&mut self, frame: Option<&FaceFrame>) {
        if let Some(f) = frame {
            let _ = self.socket.send_to(self.payload(f).as_bytes(), self.to);
        }
    }
}
