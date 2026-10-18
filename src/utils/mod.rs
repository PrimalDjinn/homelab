use std::{
    fs::File,
    io::{BufRead, BufReader},
    path::PathBuf,
};

pub fn get_first_occurrence(path: PathBuf, target: &str) -> Result<(i32, String), String> {
    let file = match File::open(path) {
        Ok(file) => file,
        Err(e) => {
            let msg = format!("An error occurred when opening the file {e}");
            return Err(msg);
        }
    };

    let reader = BufReader::new(&file);

    let mut count: i32 = 0;
    for line in reader.lines().map_while(Result::ok) {
        if line.trim().starts_with(target) {
            return Ok((count, line));
        }

        count += 1;
    }

    Err("Unable to find the signal word".into())
}
