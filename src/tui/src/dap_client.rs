use serde_json::json;
use std::error::Error;
use std::io::{BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::process::{Child, Command};

pub struct DapClient {
    child: Child,
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    seq: i64,
}

impl DapClient {
    pub fn start(server_bin: &str) -> Result<Self, Box<dyn Error>> {
        let pid = std::process::id();
        let socket_path = format!("/tmp/ct_dap_socket_{pid}");
        let _ = std::fs::remove_file(&socket_path);

        let child = Command::new(server_bin)
            .arg(&socket_path)
            .spawn()?;

        // wait for server to open socket and connect
        let mut retries = 0;
        let stream = loop {
            match UnixStream::connect(&socket_path) {
                Ok(s) => break s,
                Err(_e) if retries < 50 => {
                    std::thread::sleep(std::time::Duration::from_millis(50));
                    retries += 1;
                    continue;
                }
                Err(e) => return Err(e.into()),
            }
        };
        let reader_stream = stream.try_clone()?;

        Ok(Self {
            child,
            reader: BufReader::new(reader_stream),
            writer: stream,
            seq: 1,
        })
    }

    /// Send a launch request to the DAP server with the current process id and
    /// the path to the trace directory as custom fields.
    pub fn launch(&mut self, trace_path: &str) -> Result<(), Box<dyn Error>> {
        let seq = self.seq;
        self.seq += 1;
        let pid = std::process::id();
        let req = json!({
            "seq": seq,
            "type": "request",
            "command": "launch",
            "arguments": {
                "pid": pid,
                "tracePath": trace_path
            }
        });
        self.send_message(&req)?;
        let resp = self.read_message()?;
        if resp.get("type").and_then(|v| v.as_str()) == Some("response")
            && resp.get("command").and_then(|v| v.as_str()) == Some("launch")
            && resp.get("success").and_then(|v| v.as_bool()) == Some(true)
        {
            return Ok(());
        }
        Err("launch failed".into())
    }

    fn send_message(&mut self, msg: &serde_json::Value) -> Result<(), Box<dyn Error>> {
        let data = serde_json::to_string(msg)?;
        let header = format!("Content-Length: {}\r\n\r\n", data.len());
        self.writer.write_all(header.as_bytes())?;
        self.writer.write_all(data.as_bytes())?;
        self.writer.flush()?;
        Ok(())
    }

    fn read_message(&mut self) -> Result<serde_json::Value, Box<dyn Error>> {
        let mut header = Vec::new();
        let mut buf = [0u8; 1];
        while !header.ends_with(b"\r\n\r\n") {
            self.reader.read_exact(&mut buf)?;
            header.push(buf[0]);
        }
        let header_str = String::from_utf8(header)?;
        let len_line = header_str
            .lines()
            .find(|l| l.starts_with("Content-Length:"))
            .ok_or("missing content length")?;
        let len: usize = len_line["Content-Length:".len()..].trim().parse()?;
        let mut data = vec![0u8; len];
        self.reader.read_exact(&mut data)?;
        Ok(serde_json::from_slice(&data)?)
    }

    pub fn request_source(&mut self, path: &str) -> Result<String, Box<dyn Error>> {
        let seq = self.seq;
        self.seq += 1;
        let req = json!({
            "seq": seq,
            "type": "request",
            "command": "source",
            "arguments": {
                "source": {"path": path},
                "sourceReference": 0
            }
        });
        self.send_message(&req)?;
        let resp = self.read_message()?;
        if resp.get("type").and_then(|v| v.as_str()) == Some("response")
            && resp.get("command").and_then(|v| v.as_str()) == Some("source")
        {
            if let Some(content) = resp
                .get("body")
                .and_then(|b| b.get("content"))
                .and_then(|c| c.as_str())
            {
                return Ok(content.to_string());
            }
        }
        Err("unexpected response".into())
    }
}

