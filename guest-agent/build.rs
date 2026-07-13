fn main() {
    let proto_root = "../docs/protocols";
    let proto_file = format!("{proto_root}/agent.proto");

    println!("cargo:rerun-if-changed={proto_file}");

    tonic_build::configure()
        .build_server(true)
        .build_client(true)
        .compile_protos(&[proto_file.as_str()], &[proto_root])
        .unwrap_or_else(|e| panic!("failed to compile agent.proto: {e}"));
}
