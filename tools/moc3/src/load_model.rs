// load-model MODEL.moc3 : prints the whole parsed model (Rust Debug), for rsdebug.py
use std::{env, fs::File};

use katashiro_core::file;

fn main() {
    let args: Vec<String> = env::args().collect();
    let model = file::ParsedModel::load(&mut File::open(&args[1]).unwrap()).unwrap();
    println!("{:#?}", model);
}
