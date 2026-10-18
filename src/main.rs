mod utils;
mod proxmox;

fn main() {
    if std::env::consts::OS != "linux" {
        panic!("This program is only meant for linux");
    }
}
