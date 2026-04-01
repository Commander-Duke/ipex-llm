$cpp_dir = (Split-Path -Parent (python -c "import bigdl.cpp;print(bigdl.cpp.__file__)"))
$lib_dir = Join-Path $cpp_dir "libs\llama_cpp"
$destinationFolder = Get-Location

$files = Get-ChildItem -Path $lib_dir -File

foreach ($file in $files){
    $linkPath = Join-Path -Path $destinationFolder -ChildPath $file.Name
    New-Item -ItemType SymbolicLink -Path $linkPath -Target $file.FullName
}

$convert_path = Join-Path $cpp_dir "convert.py"
Copy-Item $convert_path -Destination $destinationFolder
