//! Reading the fit data (models/core/fit.npz from tools/export_core.py) and golden files: npz of plain arrays.

use npyz::npz::NpzArchive;
use std::fs::File;
use std::io::BufReader;
use std::path::Path;

pub struct Npz(NpzArchive<BufReader<File>>);

#[derive(Debug)]
pub struct DataError(pub String);

impl std::fmt::Display for DataError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for DataError {}

fn err(e: impl std::fmt::Display) -> DataError {
    DataError(e.to_string())
}

impl Npz {
    pub fn open(path: &Path) -> Result<Self, DataError> {
        NpzArchive::open(path).map(Npz).map_err(|e| err(format!("{}: {e}", path.display())))
    }

    /// An array as f64 with its shape, whatever its stored number type.
    pub fn f64s(&mut self, name: &str) -> Result<(Vec<f64>, Vec<u64>), DataError> {
        let arr = self.0.by_name(name).map_err(err)?.ok_or_else(|| err(format!("no array {name}")))?;
        let shape = arr.shape().to_vec();
        if arr.order() == npyz::Order::Fortran && shape.len() > 1 {
            return Err(err(format!("{name} is stored column-major, write it with np.ascontiguousarray")));
        }
        let dtype = arr.dtype();
        let v: Vec<f64> = match dtype.descr().trim_matches('\'') {
            "<f8" => arr.into_vec::<f64>().map_err(err)?,
            "<f4" => arr.into_vec::<f32>().map_err(err)?.into_iter().map(f64::from).collect(),
            "<i8" => arr.into_vec::<i64>().map_err(err)?.into_iter().map(|x| x as f64).collect(),
            "|u1" => arr.into_vec::<u8>().map_err(err)?.into_iter().map(f64::from).collect(),
            "|b1" => arr.into_vec::<bool>().map_err(err)?.into_iter().map(|b| b as u8 as f64).collect(),
            d => return Err(err(format!("{name}: unsupported dtype {d}"))),
        };
        Ok((v, shape))
    }

    pub fn ints(&mut self, name: &str) -> Result<Vec<usize>, DataError> {
        Ok(self.f64s(name)?.0.into_iter().map(|x| x as usize).collect())
    }

    pub fn scalar(&mut self, name: &str) -> Result<f64, DataError> {
        Ok(self.f64s(name)?.0[0])
    }
}
