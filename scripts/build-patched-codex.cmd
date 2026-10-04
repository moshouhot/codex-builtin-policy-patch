@echo off
REM ============================================================================
REM  Build a patched codex.exe from OpenAI's public 0.160.0 source.
REM
REM  What it does:
REM    1. Ensures the exact Rust toolchain (1.95.0) and the prebuilt rusty_v8
REM       artifacts that OpenAI publishes for release builds.
REM    2. Obtains the source tree and applies patches\is_dangerous_command.patch.
REM    3. Builds `codex.exe` in release mode.
REM
REM  Why -j 6: with the default job count (16 logical CPUs) rustc intermittently
REM  ICEs / produces corrupt crate metadata on this machine. -j 6 is stable.
REM
REM  Configuration: override any of these via environment variables before
REM  running, e.g.  set BUILD_ROOT=D:\codex && build-patched-codex.cmd
REM
REM  Output: %CARGO_TARGET_DIR%\release\codex.exe
REM ============================================================================
setlocal
REM --- configurable locations ------------------------------------------------
if not defined BUILD_ROOT set BUILD_ROOT=E:\codex-build
if not defined SRC_ROOT set SRC_ROOT=%BUILD_ROOT%\codex-0.160.0
if not defined RUSTY set RUSTY=%BUILD_ROOT%\rusty_v8
if not defined VC_VARS set VC_VARS=D:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat
set PATCHFILE=%~dp0..\patches\is_dangerous_command.patch
set V8VER=150.4.0
set PROFILE=ptrcomp_sandbox_release
set TARGET=x86_64-pc-windows-msvc

if not exist "%VC_VARS%" (
  echo [FAIL] vcvars64.bat not found at: %VC_VARS%
  echo        Set VC_VARS to your Visual Studio vcvars64.bat path.
  exit /b 1
)
call "%VC_VARS%" >nul 2>&1
if errorlevel 1 ( echo [FAIL] could not initialize MSVC environment & exit /b 1 )

REM --- toolchain -------------------------------------------------------------
rustup toolchain list | findstr /C:"1.95.0" >nul || rustup toolchain install 1.95.0 --profile minimal
if errorlevel 1 ( echo [FAIL] rustup toolchain install & exit /b 1 )

REM --- rusty_v8 artifacts ----------------------------------------------------
if not exist "%RUSTY%\rusty_v8_%PROFILE%_%TARGET%.lib.gz" (
  echo [INFO] downloading rusty_v8 artifacts...
  mkdir "%RUSTY%" 2>nul
  set BASE=https://github.com/openai/codex/releases/download/rusty-v8-v%V8VER%
  curl -fsSL -o "%RUSTY%\rusty_v8_%PROFILE%_%TARGET%.lib.gz" "%BASE%/rusty_v8_%PROFILE%_%TARGET%.lib.gz" || exit /b 1
  curl -fsSL -o "%RUSTY%\src_binding_%PROFILE%_%TARGET%.rs"  "%BASE%/src_binding_%PROFILE%_%TARGET%.rs"  || exit /b 1
)

REM --- source tree -----------------------------------------------------------
if not exist "%SRC_ROOT%\codex-rs\Cargo.toml" (
  echo [FAIL] source tree missing at %SRC_ROOT%
  echo        Extract the rust-v0.160.0 tarball there first.
  exit /b 1
)

REM --- apply patch -----------------------------------------------------------
pushd "%SRC_ROOT%"
git apply --check "%PATCHFILE%" 2>nul && git apply "%PATCHFILE%" && echo [OK] patch applied
popd

REM --- CRITICAL: migration files must be CRLF ---------------------------------
REM sqlx computes each migration's checksum from the file's RAW BYTES and stores
REM it in the database's _sqlx_migrations table. OpenAI publishes the .sql
REM migrations with CRLF line endings, so the official binary records CRLF
REM checksums. If git checks the tree out with core.autocrlf=true it rewrites
REM them to LF, the checksums change, and the patched binary then REFUSES to open
REM any database the official binary created (and vice versa) with:
REM   Error: failed to initialize sqlite state runtime under <CODEX_HOME>
REM This makes Codex Desktop fail to start ("Organization settings could not be
REM loaded"). Convert them back to CRLF before building.
python "%~dp0fix-migrations-crlf.py" "%SRC_ROOT%\codex-rs\state"
if errorlevel 1 ( echo [FAIL] migration CRLF normalization & exit /b 1 )

REM --- build -----------------------------------------------------------------
set CARGO_TARGET_DIR=%BUILD_ROOT%\target
set LIBSQLITE3_FLAGS=SQLITE_DISABLE_INTRINSIC
set RUSTY_V8_ARCHIVE=%RUSTY%\rusty_v8_%PROFILE%_%TARGET%.lib.gz
set RUSTY_V8_SRC_BINDING_PATH=%RUSTY%\src_binding_%PROFILE%_%TARGET%.rs
set STABLE_GIT_COMMIT=local-patch-0.160.0

cd /d "%SRC_ROOT%\codex-rs"
echo [INFO] building (this takes ~25 min)...
cargo +1.95.0 build --release -j 6 --bin codex
if errorlevel 1 ( echo [FAIL] cargo build & exit /b 1 )

echo.
echo [OK] built: %CARGO_TARGET_DIR%\release\codex.exe
dir /b "%CARGO_TARGET_DIR%\release\codex.exe"
endlocal
