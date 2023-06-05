use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::path::Path;

const HOST: &str = "127.0.0.1";
const PORT: i32 = 8080;

struct Request {
    method: String,
    segment: String,
}

fn handle_connection(stream: &TcpStream) -> std::io::Result<Request> {
    let mut reader = BufReader::new(stream);
    let mut buf = String::new();

    println!("> receiving query...");
    reader.read_line(&mut buf)?;

    let parts = buf.split(" ").collect::<Vec<&str>>();
    let request = Request {
        method: parts[0].to_string(),
        segment: parts[1].to_string(),
    };
    let method = parts[0];
    let segment = parts[1];
    println!("> method: {method}");
    println!("> segment: {segment}");
    println!("> end of query...");

    Ok(request)
}

fn handle_response(stream: &mut TcpStream, req: Request) {
    let path = Path::new(&req.segment).strip_prefix("/").unwrap();
    println!("> loading query: {:?}", path);
    if path.is_file() && !path.is_dir() && req.method == "GET" {
        match fs::read_to_string(path) {
            Ok(content) => {
                let content_type = "text/html";
                let content_len = content.len();
                let response = format!(
                    "HTTP/1.1 200 OK\n\
                Content-Type: {content_type}\n\
                Content-Length: {content_len}\n\n\
                {content}"
                );

                stream.write(response.as_bytes()).unwrap();
                stream.flush().unwrap();
            }
            Err(e) => {
                let content = "Not found";
                let content_type = "text/plain";
                let content_len = content.len();
                let response = format!(
                    "HTTP/1.1 404 ERROR\n\
                Content-Type: {content_type}\n\
                Content-Length: {content_len}\n\n\
                {content}"
                );

                stream.write(response.as_bytes()).unwrap();
                stream.flush().unwrap();
                println!("> {e}")
            }
        }
    }
}

fn main() {
    let listener = TcpListener::bind(format!("{HOST}:{PORT}")).unwrap();

    println!(
        "> server listening: http://{}",
        listener.local_addr().unwrap()
    );
    listener.incoming().for_each(|stream| match stream {
        Ok(mut stream) => {
            let request = handle_connection(&stream).unwrap();
            handle_response(&mut stream, request);
        }
        Err(e) => println!("couldn't get client: {e:?}"),
    });
}
