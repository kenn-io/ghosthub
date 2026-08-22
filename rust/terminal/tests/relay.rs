#[cfg(unix)]
mod unix {
    use std::ffi::{OsStr, OsString};
    use std::time::{Duration, Instant};

    use surface::{GridSize, PixelSize};
    use terminal::{ByteRelayWorker, RelayDisconnect, RelayOutput};

    const OUTPUT_BOUND: usize = 1024 * 1024;
    const POLL: Duration = Duration::from_millis(100);

    fn attach_sh(script: &str) -> ByteRelayWorker {
        ByteRelayWorker::attach_command(
            OsStr::new("/bin/sh"),
            &[OsString::from("-c"), OsString::from(script)],
            GridSize::new(80, 24).expect("valid grid"),
            PixelSize::default(),
            OUTPUT_BOUND,
        )
        .expect("attach sh relay client")
    }

    fn collect_until_disconnect(relay: &ByteRelayWorker) -> (Vec<u8>, RelayDisconnect) {
        let deadline = Instant::now() + Duration::from_mins(1);
        let mut bytes = Vec::new();
        loop {
            assert!(Instant::now() < deadline, "relay never disconnected");
            match relay.recv_output(POLL) {
                Some(RelayOutput::Bytes(chunk)) => bytes.extend_from_slice(&chunk),
                Some(RelayOutput::Disconnected(disconnect)) => return (bytes, disconnect),
                None => {}
            }
        }
    }

    fn contains(haystack: &[u8], needle: &[u8]) -> bool {
        haystack
            .windows(needle.len())
            .any(|window| window == needle)
    }

    #[test]
    fn relays_output_verbatim_and_reports_the_exit_code() {
        let relay = attach_sh("printf 'ghosthub-verbatim'; exit 7");
        let (bytes, disconnect) = collect_until_disconnect(&relay);
        assert!(
            contains(&bytes, b"ghosthub-verbatim"),
            "child output reaches the viewer untouched"
        );
        assert_eq!(disconnect, RelayDisconnect::Exited { code: 7 });
    }

    #[test]
    fn output_written_before_exit_drains_to_the_viewer() {
        let relay = attach_sh(
            "i=0; while [ $i -lt 2000 ]; do echo ghosthub-line; i=$((i+1)); done;              printf 'ghosthub-drain-end'",
        );
        let (bytes, disconnect) = collect_until_disconnect(&relay);
        assert!(
            contains(&bytes, b"ghosthub-drain-end"),
            "the final bytes written before exit still reach the viewer"
        );
        assert_eq!(disconnect, RelayDisconnect::Exited { code: 0 });
    }

    #[test]
    fn drop_releases_a_writer_blocked_by_a_non_reading_descendant() {
        // Raw mode makes the tty input queue block instead of discarding
        // over-long lines; sh stays the direct child while sleep — a
        // descendant — holds the slave and never reads. Saturated input
        // then blocks the relay writer in write_all; teardown must kill
        // the whole process group so the join stays bounded.
        let relay = attach_sh("stty raw -echo && echo desc-re''ady && sleep 600");
        let deadline = Instant::now() + Duration::from_mins(1);
        let mut output = Vec::new();
        while !contains(&output, b"desc-ready") {
            assert!(Instant::now() < deadline, "stall setup never confirmed");
            if let Some(RelayOutput::Bytes(chunk)) = relay.recv_output(POLL) {
                output.extend_from_slice(&chunk);
            }
        }
        for _ in 0..64 {
            // Overfill the few-KiB raw-mode queue; refusals once the input
            // budget backs up are expected and irrelevant here.
            let _ = relay.send_bytes(vec![b'z'; 1024]);
        }

        // Bounded observation: a wedged teardown must fail the test, not
        // hang the suite.
        let (done_tx, done_rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            drop(relay);
            let _ = done_tx.send(());
        });
        done_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("teardown joins despite the descendant holding the slave");
    }

    #[test]
    fn drop_sweeps_a_descendant_after_the_direct_child_exits_first() {
        // The exact wedge: the direct child (sh) backgrounds a non-reading
        // descendant that inherits the raw-mode slave, then exits. The
        // relay observes the child's exit, so teardown takes the natural
        // path — which must still sweep the process group, or the lingering
        // descendant keeps the writer blocked and the join hangs.
        let relay = attach_sh("stty raw -echo; printf desc-re''ady; sleep 600 & exit 0");
        let deadline = Instant::now() + Duration::from_mins(1);
        let mut output = Vec::new();
        let mut child_exited = false;
        while !child_exited {
            assert!(Instant::now() < deadline, "the direct child never exited");
            match relay.recv_output(POLL) {
                Some(RelayOutput::Bytes(chunk)) => output.extend_from_slice(&chunk),
                // The direct child's exit is the signal the natural teardown
                // path keys on; the descendant still holds the slave.
                Some(RelayOutput::Disconnected(_)) => child_exited = true,
                None => {}
            }
        }
        assert!(contains(&output, b"desc-ready"), "the descendant setup ran");
        for _ in 0..64 {
            let _ = relay.send_bytes(vec![b'z'; 1024]);
        }

        // Bounded observation: a wedged teardown fails the test instead of
        // hanging the suite.
        let (done_tx, done_rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            drop(relay);
            let _ = done_tx.send(());
        });
        done_rx
            .recv_timeout(Duration::from_secs(30))
            .expect("teardown sweeps the descendant the exited child left behind");
    }

    #[test]
    fn drop_tears_down_a_live_child_promptly() {
        let relay = attach_sh("sleep 600");
        // Drop joins the relay threads and reaps the child; a teardown
        // that waited on the sleeping child would blow this bound.
        let started = Instant::now();
        drop(relay);
        assert!(
            started.elapsed() < Duration::from_secs(20),
            "teardown reaps the live child instead of waiting for it"
        );
    }
}

#[cfg(windows)]
mod windows {
    use std::ffi::OsString;
    use std::thread;
    use std::time::{Duration, Instant};

    use session::{AttachPlan, SessionIdentity};
    use surface::{GridSize, PixelSize};
    use terminal::{ByteRelayWorker, RelayDisconnect, RelayOutput};

    const OUTPUT_BOUND: usize = 1024 * 1024;

    /// The terminal-directed cursor-position query `ConPTY` emits at startup
    /// (and after some resizes) and stalls on until the attached terminal
    /// answers. The relay forwards it to the viewer untouched; these tests
    /// play the viewer's single-VT-interpreter role and answer it, exactly
    /// as browser-side xterm.js does in production.
    const CURSOR_QUERY: &[u8] = b"\x1b[6n";
    const CURSOR_REPORT: &[u8] = b"\x1b[1;1R";

    #[test]
    fn relay_delivers_child_output_bytes_verbatim() {
        let relay = attach_cmd(
            &["/d", "/c", "echo relay-ready"],
            "relay-output-test",
            GridSize::new(40, 4).expect("valid grid"),
            OUTPUT_BOUND,
        );
        let mut client = Client::new(&relay);

        client.wait_for("relay-ready");
    }

    #[test]
    fn exit_reports_the_code_after_draining_remaining_output() {
        let relay = attach_cmd(
            &["/d", "/c", "echo tail-marker& exit /b 7"],
            "relay-exit-test",
            GridSize::new(40, 4).expect("valid grid"),
            OUTPUT_BOUND,
        );
        let mut client = Client::new(&relay);

        let disconnect = client.drain_until_disconnect();
        assert_eq!(disconnect, RelayDisconnect::Exited { code: 7 });
        assert!(
            client.text().contains("tail-marker"),
            "output emitted before exit must drain ahead of the exit report"
        );
    }

    #[test]
    fn pty_opens_at_the_required_initial_geometry() {
        let relay = attach(
            "powershell.exe",
            &[
                "-NoProfile",
                "-Command",
                "Write-Output ('w'+[console]::WindowWidth+'h'+[console]::WindowHeight)",
            ],
            "relay-geometry-test",
            GridSize::new(61, 17).expect("valid grid"),
            OUTPUT_BOUND,
        );
        let mut client = Client::new(&relay);

        client.wait_for("w61h17");
    }

    #[test]
    fn resize_applies_the_latest_geometry_to_the_pty() {
        let relay = attach_cmd(
            &["/d", "/q"],
            "relay-resize-test",
            GridSize::new(40, 10).expect("valid grid"),
            OUTPUT_BOUND,
        );
        let mut client = Client::new(&relay);
        client.wait_for(">");

        // No settling sleep: input is ordered after every resize submitted
        // before it, so the probe below must observe the coalesced geometry.
        relay
            .resize(
                GridSize::new(100, 30).expect("valid grid"),
                PixelSize::new(1_000, 600),
            )
            .expect("queue superseded resize");
        relay
            .resize(
                GridSize::new(72, 18).expect("valid grid"),
                PixelSize::new(900, 540),
            )
            .expect("queue latest resize");
        relay
            .send_bytes(
                b"powershell -NoProfile -Command \"Write-Output ('w'+[console]::WindowWidth+'h'+[console]::WindowHeight)\"\r"
                    .to_vec(),
            )
            .expect("send geometry probe");

        client.wait_for("w72h18");
    }

    #[test]
    fn input_and_resize_fail_after_the_relay_disconnects() {
        let relay = attach_cmd(
            &["/d", "/c", "exit /b 5"],
            "relay-closed-input-test",
            GridSize::new(40, 4).expect("valid grid"),
            OUTPUT_BOUND,
        );
        let mut client = Client::new(&relay);

        let disconnect = client.drain_until_disconnect();
        assert_eq!(disconnect, RelayDisconnect::Exited { code: 5 });

        let send = relay.send_bytes(b"late".to_vec());
        let error = send.expect_err("input after the observed disconnect must fail");
        assert!(!error.is_backpressure(), "stopped, not backpressured");
        assert!(
            relay
                .resize(
                    GridSize::new(90, 25).expect("valid grid"),
                    PixelSize::new(900, 500),
                )
                .is_err(),
            "resize after the observed disconnect must fail"
        );
    }

    #[test]
    fn drop_completes_teardown_before_a_fresh_attachment() {
        // The child opens a lock file with sharing denied and holds it for
        // as long as it lives, so openability of the file observes the
        // child's actual lifetime.
        let lock = std::env::temp_dir().join(format!(
            "ghosthub-relay-teardown-{}.lock",
            std::process::id()
        ));
        let _removed = std::fs::remove_file(&lock);
        // Apostrophes double inside single-quoted PowerShell strings, so a
        // temp path containing one cannot break the command.
        let quoted_lock = lock.display().to_string().replace('\'', "''");
        let hold = format!(
            "$f=[IO.File]::Open('{quoted_lock}','Create','Write','None'); \
             Write-Output ready; Start-Sleep -Seconds 3600"
        );
        let first = attach(
            "powershell.exe",
            &["-NoProfile", "-Command", &hold],
            "relay-teardown-test",
            GridSize::new(60, 10).expect("valid grid"),
            OUTPUT_BOUND,
        );
        Client::new(&first).wait_for("ready");
        assert!(lock.exists(), "the child must have created the lock file");
        assert!(
            std::fs::OpenOptions::new().write(true).open(&lock).is_err(),
            "the live child must hold the lock file exclusively"
        );

        // Drop joins the relay and writer threads after reaping the child;
        // the child's death is therefore caused by drop, not by test
        // timing. Windows releases a killed console child's file handles
        // asynchronously shortly after its process handle signals, so the
        // observation polls with a tight deadline rather than expecting the
        // lock to be free in the same instant drop returns.
        drop(first);
        let deadline = Instant::now() + Duration::from_secs(2);
        let released = std::iter::from_fn(|| {
            (Instant::now() < deadline).then(|| {
                std::fs::OpenOptions::new().write(true).open(&lock).is_ok() || {
                    thread::sleep(Duration::from_millis(10));
                    false
                }
            })
        })
        .any(|ok| ok);
        assert!(
            released,
            "drop must tear the child down and release its lock"
        );
        let _removed = std::fs::remove_file(&lock);

        let second = attach_cmd(
            &["/d", "/q"],
            "relay-teardown-test",
            GridSize::new(60, 10).expect("valid grid"),
            OUTPUT_BOUND,
        );
        Client::new(&second).wait_for(">");
    }

    #[test]
    fn relay_writes_no_bytes_the_client_did_not_send() {
        // ConPTY's startup cursor query is a terminal-directed device query:
        // any VT interpreter on the relay path would consume it and write a
        // synthesized report back into the PTY, unblocking the child without
        // the client's involvement (the parsed worker does exactly that).
        // The relay must instead surface the query bytes verbatim and leave
        // the PTY input untouched until the client answers.
        let relay = attach_cmd(
            &["/d", "/v:on", "/c", "set /p reply= & echo got:!reply!"],
            "relay-no-parser-test",
            GridSize::new(80, 8).expect("valid grid"),
            OUTPUT_BOUND,
        );

        let deadline = Instant::now() + Duration::from_secs(20);
        let mut collected = Vec::new();
        while !contains(&collected, CURSOR_QUERY) {
            match relay.recv_output(Duration::from_millis(50)) {
                Some(RelayOutput::Bytes(bytes)) => collected.extend_from_slice(&bytes),
                Some(RelayOutput::Disconnected(disconnect)) => {
                    panic!("relay disconnected before the device query: {disconnect:?}")
                }
                None => {}
            }
            assert!(
                Instant::now() < deadline,
                "the device query was not relayed verbatim: {}",
                String::from_utf8_lossy(&collected).escape_debug()
            );
        }

        // Nothing on the relay path answers the query: the child stays
        // blocked behind ConPTY's handshake until this client responds.
        assert_eq!(
            relay.recv_output(Duration::from_millis(500)),
            None,
            "no relay-side interpreter may answer the device query"
        );

        relay
            .send_bytes(CURSOR_REPORT.to_vec())
            .expect("answer the query as the client");
        relay
            .send_bytes(b"pong\r".to_vec())
            .expect("send the client's line");

        let mut client = Client::resume(&relay, collected);
        let disconnect = client.drain_until_disconnect();
        assert!(
            client.text().contains("got:pong"),
            "the child must receive exactly the client's bytes: {}",
            client.text().escape_debug()
        );
        assert!(matches!(disconnect, RelayDisconnect::Exited { .. }));
    }

    #[test]
    fn undrained_output_beyond_the_bound_disconnects_the_relay() {
        // The bound is the enforced minimum (one reader chunk); the child
        // must genuinely overrun it while the queue sits undrained.
        let relay = attach_cmd(
            &[
                "/d",
                "/c",
                "for /l %i in (1,1,5000) do @echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            ],
            "relay-backpressure-test",
            GridSize::new(80, 8).expect("valid grid"),
            64 * 1024,
        );
        // Answer the startup handshake, then leave the queue undrained long
        // enough for the child to overrun the small bound.
        let mut client = Client::new(&relay);
        client.wait_for_bytes(CURSOR_QUERY);
        thread::sleep(Duration::from_secs(2));

        let disconnect = client.drain_until_disconnect();
        assert_eq!(disconnect, RelayDisconnect::Backpressure);
    }

    #[test]
    fn input_to_a_stopped_relay_is_not_backpressure() {
        // The web attach path closes with POLICY only on genuine
        // backpressure; a stopped relay's send error must classify
        // differently so a normal exit is never masked as input overflow.
        let relay = attach_cmd(
            &["/d", "/c", "echo relay-stopped-input"],
            "relay-stopped-input-test",
            GridSize::new(40, 4).expect("valid grid"),
            OUTPUT_BOUND,
        );
        let mut client = Client::new(&relay);
        let disconnect = client.drain_until_disconnect();
        assert!(matches!(disconnect, RelayDisconnect::Exited { .. }));

        let error = relay
            .send_bytes(b"z".to_vec())
            .expect_err("a stopped relay refuses input");
        assert!(
            !error.is_backpressure(),
            "a stopped relay's refusal is not backpressure"
        );
    }

    fn attach_cmd(
        args: &[&str],
        name: &str,
        size: GridSize,
        max_queued_output_bytes: usize,
    ) -> ByteRelayWorker {
        attach("cmd.exe", args, name, size, max_queued_output_bytes)
    }

    fn attach(
        program: &str,
        args: &[&str],
        name: &str,
        size: GridSize,
        max_queued_output_bytes: usize,
    ) -> ByteRelayWorker {
        let plan = AttachPlan::attach_only(
            program,
            args.iter().map(OsString::from).collect(),
            name,
            SessionIdentity::new(1, "$1", 1),
        );
        ByteRelayWorker::attach(&plan, size, PixelSize::default(), max_queued_output_bytes)
            .expect("attach ConPTY relay client")
    }

    fn contains(haystack: &[u8], needle: &[u8]) -> bool {
        haystack
            .windows(needle.len())
            .any(|window| window == needle)
    }

    /// A minimal stand-in for the viewer's terminal: collects relayed bytes
    /// and answers each cursor-position query, the one terminal-directed
    /// device query `ConPTY` requires an answer to.
    struct Client<'relay> {
        relay: &'relay ByteRelayWorker,
        collected: Vec<u8>,
        answered: usize,
    }

    impl<'relay> Client<'relay> {
        fn new(relay: &'relay ByteRelayWorker) -> Self {
            Self::resume(relay, Vec::new())
        }

        fn resume(relay: &'relay ByteRelayWorker, collected: Vec<u8>) -> Self {
            let mut client = Self {
                relay,
                collected,
                answered: 0,
            };
            client.answer_queries();
            client
        }

        fn text(&self) -> String {
            String::from_utf8_lossy(&self.collected).into_owned()
        }

        fn wait_for(&mut self, expected: &str) {
            self.wait_for_bytes(expected.as_bytes());
        }

        fn wait_for_bytes(&mut self, expected: &[u8]) {
            let deadline = Instant::now() + Duration::from_secs(20);
            while !contains(&self.collected, expected) {
                match self.pump() {
                    None => assert!(
                        Instant::now() < deadline,
                        "relay output did not contain {:?}: {}",
                        String::from_utf8_lossy(expected),
                        self.text().escape_debug()
                    ),
                    Some(disconnect) => panic!(
                        "relay disconnected ({disconnect:?}) before output contained {:?}: {}",
                        String::from_utf8_lossy(expected),
                        self.text().escape_debug()
                    ),
                }
            }
        }

        fn drain_until_disconnect(&mut self) -> RelayDisconnect {
            let deadline = Instant::now() + Duration::from_secs(20);
            loop {
                if let Some(disconnect) = self.pump() {
                    return disconnect;
                }
                assert!(
                    Instant::now() < deadline,
                    "relay did not report a disconnect: {}",
                    self.text().escape_debug()
                );
            }
        }

        fn pump(&mut self) -> Option<RelayDisconnect> {
            match self.relay.recv_output(Duration::from_millis(50)) {
                Some(RelayOutput::Bytes(bytes)) => {
                    self.collected.extend_from_slice(&bytes);
                    self.answer_queries();
                    None
                }
                Some(RelayOutput::Disconnected(disconnect)) => Some(disconnect),
                None => None,
            }
        }

        fn answer_queries(&mut self) {
            let queries = self
                .collected
                .windows(CURSOR_QUERY.len())
                .filter(|window| *window == CURSOR_QUERY)
                .count();
            while self.answered < queries {
                // A stopped relay ends the test through its disconnect
                // outcome; the answer itself is best-effort.
                let _ignored = self.relay.send_bytes(CURSOR_REPORT.to_vec());
                self.answered += 1;
            }
        }
    }
}
