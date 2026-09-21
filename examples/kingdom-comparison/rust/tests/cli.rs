use std::process::{Command, Output};

fn run(arguments: &[&str]) -> Output {
    Command::new(std::env::var_os("KINGDOM_BIN").expect("KINGDOM_BIN must identify the built CLI"))
        .args(arguments)
        .output()
        .expect("kingdom CLI should start")
}

#[test]
fn no_arguments_has_no_output_and_succeeds() {
    let output = run(&[]);
    assert!(output.status.success());
    assert_eq!(output.stdout, b"");
    assert_eq!(output.stderr, b"");
}

#[test]
fn mixed_sequence_has_exact_state_lines() {
    let output = run(&[
        "buy1",
        "mortgage0",
        "repay1",
        "pass1",
        "buy0",
        "repay0",
        "buy1",
        "mortgage0",
        "pass0",
        "mortgage1",
        "pass0",
        "repay1",
        "buy0",
    ]);
    assert!(output.status.success());
    assert_eq!(output.stderr, b"");
    assert_eq!(
        String::from_utf8(output.stdout).expect("CLI output should be UTF-8"),
        concat!(
            "error 20 20 100 0 0 0\n",
            "ok 25 20 95 0 1 1\n",
            "error 25 20 95 0 1 1\n",
            "ok 25 20 95 0 1 0\n",
            "error 25 20 95 0 1 0\n",
            "ok 20 20 100 0 0 1\n",
            "ok 30 10 100 1 0 0\n",
            "error 30 10 100 1 0 0\n",
            "ok 30 10 100 1 0 1\n",
            "ok 30 15 95 1 1 0\n",
            "ok 30 15 95 1 1 1\n",
            "ok 30 10 100 1 0 0\n",
            "ok 20 20 100 0 0 1\n",
        )
    );
}

#[test]
fn malformed_tokens_each_emit_an_unchanged_error_state() {
    let output = run(&["pass0 pass1", "PASS0", "pass2", ""]);
    assert!(output.status.success());
    assert_eq!(output.stderr, b"");
    assert_eq!(
        String::from_utf8(output.stdout).expect("CLI output should be UTF-8"),
        "error 20 20 100 0 0 0\n".repeat(4)
    );
}

#[cfg(unix)]
#[test]
fn non_utf8_token_is_a_normal_rejection() {
    use std::ffi::OsString;
    use std::os::unix::ffi::OsStringExt;

    let output = Command::new(
        std::env::var_os("KINGDOM_BIN").expect("KINGDOM_BIN must identify the built CLI"),
    )
    .arg(OsString::from_vec(b"pass0\xff".to_vec()))
    .output()
    .expect("kingdom CLI should start");
    assert!(output.status.success());
    assert_eq!(output.stdout, b"error 20 20 100 0 0 0\n");
    assert_eq!(output.stderr, b"");
}
