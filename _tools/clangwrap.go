package main
import (
  "os"
  "os/exec"
)
func main() {
  if len(os.Args) < 3 { os.Exit(2) }
  mode := os.Args[1]
  exe := `C:\Program Files (x86)\Intel\oneAPI\compiler\latest\bin\compiler\clang.exe`
  if mode == "cxx" { exe = `C:\Program Files (x86)\Intel\oneAPI\compiler\latest\bin\compiler\clang++.exe` }
  args := make([]string, 0, len(os.Args))
  args = append(args, "-Qunused-arguments")
  for _, a := range os.Args[2:] {
    if a == "-mthreads" { continue }
    args = append(args, a)
  }
  cmd := exec.Command(exe, args...)
  cmd.Stdout = os.Stdout
  cmd.Stderr = os.Stderr
  cmd.Stdin = os.Stdin
  cmd.Env = os.Environ()
  err := cmd.Run()
  if err == nil { return }
  if ee, ok := err.(*exec.ExitError); ok { os.Exit(ee.ExitCode()) }
  os.Exit(1)
}
