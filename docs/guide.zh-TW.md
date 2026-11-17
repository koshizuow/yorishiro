# Yorishiro 使用說明

[English](guide.md) · [日本語](guide.ja.md)

- [開始使用](#開始使用)
- [快捷鍵](#快捷鍵)
- [OBS](#obs)
- [虛擬攝影機](#虛擬攝影機)
- [左右方向](#左右方向)
- [道具](#道具)
- [iPhone 追蹤](#iphone-追蹤)
- [多人共用一台電腦](#多人共用一台電腦)
- [疑難排解](#疑難排解)

## 開始使用

1. 從 [Releases](https://github.com/koshizuow/yorishiro/releases) 下載 AppImage，執行
   `chmod +x Yorishiro-<version>-x86_64.AppImage` 後開啟。
2. 舞台中央的卡片會帶你選模型、確認臉部追蹤、擺放模型。Live2D 模型是一個含 `.model3.json` 的資料夾，放在
   `~/.local/share/yorishiro/Live2DModels/` 的模型會自動出現。
3. 放鬆表情看著攝影機一下，或使用 Sensitivity 頁面的 **Auto calibrate**。校正一次一步，可以看完說明再做。
4. 拖曳可以移動模型，滾輪或雙指縮放可以調整大小，按住 Shift 滾動可以傾斜。角落的齒輪開啟所有設定。
5. 想讓 Yorishiro 出現在應用程式選單，Dock 也顯示圖示，到「關於」頁按 **加到應用程式選單**。移動檔案後再按一次。檔案管理器裡的檔案本身可能仍是一般圖示，這取決於你的桌面環境。

## 快捷鍵

模型如果自帶快捷鍵，載入後就能用。要查看或修改，打開設定裡的 **Hotkeys** 頁面，要先載入模型。

- **改按鍵：** 點該項的按鍵欄位，再同時按住新的按鍵，最多三個，例如 Ctrl+M 或 Tab+F1，放開時設定完成。Esc 取消，Backspace 清除。
- **新增：** 按 **Add hotkey**，再選要做的事：表情、動畫或 app 動作。
- **Hold：** 開啟後，只有按住按鍵時才有作用。

鍵盤快捷鍵在 app 視窗有焦點時可以用。想在其他視窗也能用，例如 OBS 或遊戲在前景時，把使用者加入 `input` 群組並重新登入：

```sh
sudo usermod -aG input $USER
```

加入後你執行的所有程式都能讀取鍵盤，所以有需要再加。可以用 `id -nG` 確認。

## OBS

舞台畫面會帶著透明背景傳到 OBS，不含 app 的按鈕和選單。

需要：

- PipeWire 1.4 以上。Ubuntu 25.10、26.04 和 Debian 13 已內建。Ubuntu 24.04 和 Linux Mint 22 是 1.0，除非更新 PipeWire，否則
  app 能跑但沒有這個輸出。
- Vulkan 繪圖，這是預設值。
- OBS 32 以上，加上 [obs-pwvideo](https://github.com/hoshinolina/obs-pwvideo) plugin，這是獨立專案。OBS 不會載入給比自己新的
  版本編譯的 plugin，而 plugin 的 Releases 是給 OBS 32 編的。Ubuntu 26.04 內建 OBS 32。Debian 13 和 Ubuntu 25.10 內建
  OBS 30，請改用 Flatpak 版 OBS。

從 [plugin 的 Releases](https://github.com/hoshinolina/obs-pwvideo/releases) 下載，依你用的 OBS 安裝：

- **發行版內建的 OBS**（apt、dnf、pacman 裝的）：把 `obs-pwvideo-<版本>-x86_64-ubuntu-gnu.tar.xz` 解壓到 OBS 的設定目錄：

  ```bash
  mkdir -p ~/.config/obs-studio/plugins
  tar xJf obs-pwvideo-<版本>-x86_64-ubuntu-gnu.tar.xz -C ~/.config/obs-studio/plugins
  ```

  Ubuntu 和 Debian 也可以用 `.deb`，會裝給所有使用者：`sudo apt install ./obs-pwvideo-<版本>-x86_64-linux-gnu.deb`。
- **Flathub 的 OBS**（`com.obsproject.Studio`）：Flatpak 版的設定在別的地方，把同一個檔案解壓到那裡：

  ```bash
  mkdir -p ~/.var/app/com.obsproject.Studio/config/obs-studio/plugins
  tar xJf obs-pwvideo-<版本>-x86_64-ubuntu-gnu.tar.xz -C ~/.var/app/com.obsproject.Studio/config/obs-studio/plugins
  ```

重新啟動 OBS。在「說明 > 記錄檔」裡會看到 `[obs-pwvideo] plugin loaded successfully`。

接著：

1. 在 Yorishiro 開啟 **Send the stage to OBS (PipeWire, transparent)**。
2. 在 OBS 新增 **PipeWire video** 來源，選 Yorishiro。

視窗被遮住或最小化時，app 會繼續送畫面，所以 OBS 可以蓋在上面。

## 虛擬攝影機

給只吃攝影機的 app 用，例如 Google Meet。攝影機沒有透明，所以會顯示 app 的背景，也就是你選的圖片或顏色，透明模式下是黑色。換背景時攝影機會跟著變。

在 Ubuntu 上：

```sh
sudo apt install v4l2loopback-dkms
sudo modprobe v4l2loopback devices=1 video_nr=20 card_label="Yorishiro" exclusive_caps=1
```

`modprobe` 那行效力到重開機為止。App 找不到裝置時會顯示這行指令，按 **Check again** 不用重開 app 就能重新偵測。接著在
攝影機面板選裝置、開啟虛擬攝影機，再到另一個 app 選 **Yorishiro** 當攝影機。

畫面尺寸固定為攝影機開啟時的大小，調整視窗時舞台會縮放到這個尺寸，另一個 app 可以繼續使用。

## 左右方向

Yorishiro 就像照鏡子。你往自己的右邊看，模型就往畫面右邊轉。

OBS、直播和通話裡的其他人，看到的都和 app 視窗相同。Google Meet 這類通話軟體通常只翻轉**你自己的預覽**，所以你的預覽可能和
app 左右相反，其他人看到的方向仍然正確。

## 道具

設定的 **模型與道具** 頁可以加道具：圖片（PNG、JPG，也可以是動態 GIF、APNG、WebP）、一個放連續圖片的資料夾，或
Live2D 模型（含 `.model3.json` 的資料夾）。放在 `~/.local/share/yorishiro/Items/` 的道具會自動出現在道具庫。Live2D
道具也會跟著臉部追蹤做表情。

- 打開道具的圖釘按鈕，再把道具拖到模型上放開，道具就釘在底下的網格，跟著那個部位一起動。旁邊的按鈕也可以直接選網格。釘住的道具存在模型的設定裡，下次載入模型會自己回來。
- 道具預設畫在模型最上層。按道具的 **圖層** 按鈕選一個網格，道具就畫在那個網格正上方、之後的網格下面，例如夾在帽子和帽簷之間。

**從 VTube Studio 搬過來。** 把 VTube Studio 的模型資料夾放進 `Live2DModels/`，用到的道具（VTube Studio 的
`StreamingAssets/Items` 裡的檔案）放進 `Items/`。載入模型時，VTube Studio 釘在模型上的道具會照原本的位置、大小和圖層出現，
Live2D 道具的前後切半和存下的表情也一樣。在 Yorishiro 改過之後，就以 Yorishiro 存的為準。**道具場景** 的 **載入** 可以讀
VTube Studio 存的道具場景。場景裡沒釘住的道具，大小目前是推算的，可能和 VTube Studio 不同。

## iPhone 追蹤

裝了 VTube Studio 的 iPhone 可以取代網路攝影機來追蹤臉部。有兩種連法，都用 iPhone 實測過，模型跟網路攝影機一樣像照鏡子。

**PC 連線（為 VTube Studio 做的模型建議用這種）。** 手機自己算出模型的輸入（頭的角度、眼睛、嘴巴），用的是手機上的校正，跟電腦版 VTube
Studio 拿到的值一樣。模型設定是照這些值調的（例如眼睛在 0.5 就全開），看起來會跟在 VTube Studio 裡一樣。

1. 在 Yorishiro 打開攝影機面板，追蹤來源選 **VTube Studio（Wi-Fi）**，按 **啟動伺服器**。面板會顯示這台電腦的位址。
2. iPhone 連上同一個 Wi-Fi。在 VTube Studio 打開設定（齒輪），在 PC 連線（Wi-Fi）的區塊填入那個位址和面板上的連接埠（第一份 app 是 25565），打開 **PCと接続する**
   （英文介面是 Connect to PC）。
3. 手機連上後面板會變成 On。如果一直停在「等待連線」，可能是電腦的防火牆擋了這個 TCP 連接埠。用 ufw 的話：`sudo ufw allow 25565/tcp`。
   如果面板顯示連接埠被其他程式使用中，在面板換一個連接埠，手機也填一樣的號碼。

**VSeeFace 模式。** 手機送出原始的臉部形狀（52 個 ARKit 數值），由 Yorishiro 自己算出輸入。這個功能免費。

1. iPhone 連上同一個 Wi-Fi。如果下面看到的 IP 跟家裡其他裝置不像（例如不是 `192.168.x.x`），把行動數據關掉。
2. 在 VTube Studio 點一次相機按鈕，讓追蹤開始。
3. 打開設定，往下拉到 **VSeeFace** 的區塊，打開 **Activate**（日文介面是「アクティブ」）。
4. 按 **Show IP list**（「IPを示す」），記下 IPv4 位址。連接埠固定是 21412。
5. 在 Yorishiro 追蹤來源選 **iOS 表情形狀（VTS）**，在 **主機名稱（手機）** 填手機的位址，按 **連線到手機**。手機的 **Connected VSF
   Clients** 下面會出現這台電腦。
6. 如果收不到資料，可能是防火牆擋了資料進來的 UDP 連接埠，也就是面板上的 **這台電腦的連接埠**（第一份是 50650）：
   `sudo ufw allow 50650/udp`。這個連接埠可以在面板改，會自動告訴手機。

兩種都適用：

- 手機上的 VTube Studio 要保持開著、螢幕亮著。app 退到背景時模型會停住。
- PC 連線區塊的 **配信モード**（Streaming Mode）會在電腦連上後讓手機螢幕變暗，想看手機畫面就關掉。
- 一次只用一種。

## 多人共用一台電腦

再開一次 app 就好。每份會自動編下一個號碼，也可以用 `--instance=2` 指定。

- 每份有自己的設定，會自動選空閒的攝影機。模型庫共用。
- OBS 串流名稱是 `Yorishiro`、`Yorishiro-2`，依此類推。Plugin 連接埠是 8001、8002，依此類推。
- 兩台 iPhone：每份各接一台。PC 連線模式每份聽不同的連接埠（25565、25566，依此類推，面板上會顯示），在各自的手機填那份的連接埠。
  VSeeFace 模式不用另外設定。
- 兩份不能同時讀同一顆攝影機。第二份會顯示攝影機忙碌，但不會當掉。

每份都各自跑追蹤，能開幾份取決於你的電腦。

## 疑難排解

| 看到的狀況 | 處理方式 |
|---|---|
| Wayland 上視窗約一分鐘才出現 | 桌面 portal 沒有回應。安裝並啟動你桌面用的後端，例如 `xdg-desktop-portal-wlr` 或 `xdg-desktop-portal-hyprland`。 |
| 按快捷鍵沒反應 | 先點 app 視窗讓它有焦點。其他視窗請看[快捷鍵](#快捷鍵)。 |
| OBS 裡沒有 Yorishiro 來源 | 確認 **Send the stage to OBS** 已開啟，再檢查 plugin 和 OBS 版本。 |
| 虛擬攝影機清單沒有裝置 | 執行[虛擬攝影機](#虛擬攝影機)的 `modprobe` 那行，再按 **Check again**。重開機後要再執行一次。 |
| iPhone 追蹤一直停在「等待連線」 | 確認位址、手機跟電腦在同一個 Wi-Fi，再檢查防火牆，見 [iPhone 追蹤](#iphone-追蹤)。 |
| 攝影機忙碌 | 別的 app 或另一份 Yorishiro 正在使用。關掉它，或選別顆攝影機。 |
