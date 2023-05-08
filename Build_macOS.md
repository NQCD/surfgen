# Building surfgen for macOS (arm64)
**Using Homebrew versions GNU compilers**

## Install Homebrew dependencies
```shell
brew install gcc gfortran
```

## Build `surfgen`
**Caution:** The working directory can't contain any spaces. 
```shell
make FC=/opt/homebrew/bin/gfortran CC=/opt/homebrew/bin/gcc-13 CXX=/opt/homebrew/bin/g++-13 FFLAGS=-fallow-argument-mismatch
```

`libsurfgen.a` now exists in `/lib`. 
