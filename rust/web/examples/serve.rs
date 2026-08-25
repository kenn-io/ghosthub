//! Developer launcher: start the loopback web server and print the one-time
//! bootstrap URL, then serve until interrupted.
//!
//! ```text
//! cargo run -p ghosthub-web --example serve
//! ```

fn main() -> std::io::Result<()> {
    let server = web::Server::start()?;
    println!("Ghosthub web UI listening on http://{}", server.addr());
    println!("Open this one-time bootstrap URL in a browser:");
    println!("{}", server.bootstrap_url());
    loop {
        std::thread::park();
    }
}
