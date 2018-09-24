version 1.0

task a {
  input {
    File f
  }
  command {
    echo ~{f}
  }
  runtime {
    docker: "ubuntu:latest"
  }
  output {
    Boolean done = true
  }
}

task b {
  input {
    File f
    Boolean ready
  }
  command {
    echo ~{f}
  }
  runtime {
    docker: "ubuntu:latest"
  }
}

workflow w {
  input {
    File f
  }
  call a {input: f = f}
  call b {input: ready = a.done, f = f}
}


