"""
Out-of-container maintenance API for Rebecca installations.

This FastAPI service stays outside the docker stack and exposes a very small
surface that can be wired to systemd. All operations are executed via the
existing `rebecca` CLI (update / restart / backup) or Docker Compose (restore).

Environment variables are read from Rebecca's `.env` file as well as the host
environment. The most important knobs are:

    REBECCA_SCRIPT_HOST        (default: 127.0.0.1)
    REBECCA_SCRIPT_PORT        (default: 3000)
    REBECCA_SCRIPT_ALLOWED_HOSTS   (default: 127.0.0.1,::1,localhost)
    REBECCA_SCRIPT_BIN         (default: resolved `rebecca` CLI)
    REBECCA_APP_NAME           (default: rebecca)
    REBECCA_INSTALL_DIR        (default: /opt)
    REBECCA_APP_DIR            (default: /opt/<app_name>)
    REBECCA_DATA_DIR           (default: /var/lib/<app_name>)
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
from datetime import datetime, timedelta
from pathlib import Path
from typing import Dict, Iterable, List, Optional

try:
    import pymysql
except ImportError:
    pymysql = None  # pymysql is optional, only needed for MySQL/MariaDB

import uvicorn
import yaml
from fastapi import BackgroundTasks, Body, FastAPI, File, HTTPException, Query, Request, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, EmailStr, field_validator

logger = logging.getLogger("rebecca.scripts.api")
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

MAINT_SOURCE_URL = os.getenv(
    "REBECCA_MAINT_SOURCE_URL",
    "https://github.com/rebeccapanel/Rebecca/raw/master/Rebecca-scripts/main.py",
)
MAINT_UNIT_NAME = os.getenv("REBECCA_MAINT_UNIT", "rebecca-maint.service")


class Settings:
    def __init__(self) -> None:
        self.host = os.getenv("REBECCA_SCRIPT_HOST", os.getenv("UVICORN_HOST", "127.0.0.1"))
        self.port = int(os.getenv("REBECCA_SCRIPT_PORT", os.getenv("REBECCA_MAINT_PORT", "3000")))
        allowed = os.getenv("REBECCA_SCRIPT_ALLOWED_HOSTS", "127.0.0.1,::1,localhost")
        self.allowed_hosts = {host.strip() for host in allowed.split(",") if host.strip()}

        self.app_name = os.getenv("REBECCA_APP_NAME", "rebecca")
        install_dir = Path(os.getenv("REBECCA_INSTALL_DIR", "/opt"))
        self.app_dir = Path(os.getenv("REBECCA_APP_DIR", install_dir / self.app_name)).resolve()
        self.data_dir = Path(
            os.getenv("REBECCA_DATA_DIR", f"/var/lib/{self.app_name}")
        ).resolve()

        self.env_file = Path(os.getenv("REBECCA_ENV_FILE", self.app_dir / ".env"))
        self.compose_file = Path(
            os.getenv("REBECCA_COMPOSE_FILE", self.app_dir / "docker-compose.yml")
        )
        self.backup_dir = Path(os.getenv("REBECCA_BACKUP_DIR", self.app_dir / "backup"))
        self.compose_project = os.getenv("REBECCA_COMPOSE_PROJECT", self.app_name)
        self.service_name = os.getenv("REBECCA_SERVICE_NAME", self.app_name)

        self.node_app_dir = Path(os.getenv("REBECCA_NODE_APP_DIR", "/opt/rebecca-node")).resolve()
        self.node_compose_file = Path(
            os.getenv("REBECCA_NODE_COMPOSE_FILE", self.node_app_dir / "docker-compose.yml")
        )
        self.node_service_name = os.getenv("REBECCA_NODE_SERVICE_NAME", "rebecca-node")

        self.rebecca_cli = self._resolve_rebecca_cli()
        self.compose_binary = self._resolve_compose_binary()

    @staticmethod
    def _resolve_rebecca_cli() -> Path:
        user_defined = os.getenv("REBECCA_SCRIPT_BIN")
        candidates: Iterable[Path] = []

        if user_defined:
            candidates = [Path(user_defined)]
        else:
            detected = shutil.which("rebecca")
            fallback = Path(__file__).resolve().parent / "rebecca.sh"
            candidates = [Path(detected)] if detected else []
            candidates.append(fallback)

        for candidate in candidates:
            if candidate and candidate.exists():
                return candidate
        raise RuntimeError("Unable to locate the rebecca CLI. Set REBECCA_SCRIPT_BIN.")

    @staticmethod
    def _resolve_compose_binary() -> List[str]:
        if shutil.which("docker-compose"):
            return ["docker-compose"]
        if shutil.which("docker"):
            return ["docker", "compose"]
        raise RuntimeError("docker compose is not installed or not in PATH")

    def compose_cmd(self, *args: str) -> List[str]:
        return (
            self.compose_binary
            + ["-f", str(self.compose_file), "-p", self.compose_project]
            + list(args)
        )


settings = Settings()
app = FastAPI(title="Rebecca Maintenance API", version="0.1.0")
DOMAIN_PATTERN = re.compile(r"^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$")

BACKUP_MAX_FILES = int(os.getenv("REBECCA_BACKUP_MAX_FILES", "20"))
BACKUP_RETENTION_DAYS = int(os.getenv("REBECCA_BACKUP_RETENTION_DAYS", "14"))

MYSQL_DEFAULT_DATABASES = {
    "information_schema",
    "performance_schema",
    "mysql",
    "sys",
    "phpmyadmin",
}


def load_compose_file(path: Path) -> Dict:
    if not path.exists():
        raise HTTPException(status_code=404, detail=f"Compose file not found at {path}")
    try:
        data = yaml.safe_load(path.read_text()) or {}
    except yaml.YAMLError as exc:
        raise HTTPException(status_code=500, detail=f"Failed to parse compose file: {exc}") from exc
    return data


def extract_image_tag(image: str) -> Optional[str]:
    if ":" not in image:
        return None
    return image.rsplit(":", 1)[1]


def get_service_image_info(compose_path: Path, service_name: str) -> Dict[str, Optional[str]]:
    compose = load_compose_file(compose_path)
    services = compose.get("services") or {}
    service = services.get(service_name)
    if not service:
        raise HTTPException(
            status_code=404, detail=f"Service '{service_name}' not defined in {compose_path}"
        )
    image = service.get("image")
    if not image:
        raise HTTPException(
            status_code=400, detail=f"Service '{service_name}' in {compose_path} does not define an image"
        )
    return {"image": image, "tag": extract_image_tag(image)}


def detect_architecture() -> str:
    machine = platform.machine().lower()
    mapping = {
        "i386": "32",
        "i686": "32",
        "x86_64": "64",
        "amd64": "64",
        "armv5tel": "arm32-v5",
        "armv6l": "arm32-v6",
        "armv7l": "arm32-v7a",
        "armv7": "arm32-v7a",
        "arm64": "arm64-v8a",
        "aarch64": "arm64-v8a",
        "mips": "mips32",
        "mipsle": "mips32le",
        "mips64": "mips64",
        "mips64le": "mips64le",
        "ppc64": "ppc64",
        "ppc64le": "ppc64le",
        "riscv64": "riscv64",
        "s390x": "s390x",
    }
    if machine not in mapping:
        raise HTTPException(status_code=400, detail=f"Unsupported architecture: {machine}")
    arch = mapping[machine]
    if arch == "arm32-v6":
        arch = "arm32-v5"
    return arch


def resolve_xray_tag(version: Optional[str]) -> str:
    if version and version.lower() != "latest":
        return version
    try:
        req = urllib.request.Request(
            "https://api.github.com/repos/XTLS/Xray-core/releases/latest",
            headers={"User-Agent": "Rebecca-Maintenance-Service"},
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
        return payload.get("tag_name")
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"Failed to resolve latest Xray version: {exc}") from exc


def download_release_archive(tag: str, arch: str) -> Path:
    url = f"https://github.com/XTLS/Xray-core/releases/download/{tag}/Xray-linux-{arch}.zip"
    tmp_dir = Path(tempfile.mkdtemp())
    zip_path = tmp_dir / "xray.zip"
    req = urllib.request.Request(url, headers={"User-Agent": "Rebecca-Maintenance-Service"})
    try:
        with urllib.request.urlopen(req, timeout=300) as resp, zip_path.open("wb") as handle:
            shutil.copyfileobj(resp, handle)
    except urllib.error.URLError as exc:
        shutil.rmtree(tmp_dir, ignore_errors=True)
        raise HTTPException(status_code=502, detail=f"Failed to download Xray release: {exc}") from exc

    try:
        with zipfile.ZipFile(zip_path) as archive:
            archive.extractall(tmp_dir)
    except zipfile.BadZipFile as exc:
        shutil.rmtree(tmp_dir, ignore_errors=True)
        raise HTTPException(status_code=500, detail=f"Downloaded archive is corrupted: {exc}") from exc

    return tmp_dir


def get_xray_paths() -> tuple[Path, Path]:
    env_values = load_env_file(settings.env_file)
    exec_path = Path(env_values.get("XRAY_EXECUTABLE_PATH", "/usr/local/bin/xray"))
    assets_path = Path(env_values.get("XRAY_ASSETS_PATH", "/usr/local/share/xray"))
    return exec_path, assets_path


def install_xray_assets(
    version: Optional[str],
    include_binary: bool = True,
    include_geo: bool = True,
) -> str:
    if not include_binary and not include_geo:
        return ""

    arch = detect_architecture()
    tag = resolve_xray_tag(version)
    tmp_dir = download_release_archive(tag, arch)
    try:
        exec_path, assets_path = get_xray_paths()
        if include_binary:
            source_binary = tmp_dir / "xray"
            if not source_binary.exists():
                raise HTTPException(status_code=500, detail="Downloaded archive missing xray binary")
            exec_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source_binary, exec_path)
            os.chmod(exec_path, 0o755)

        if include_geo:
            assets_path.mkdir(parents=True, exist_ok=True)
            for geo_name in ("geoip.dat", "geosite.dat"):
                source = tmp_dir / geo_name
                if not source.exists():
                    raise HTTPException(
                        status_code=500, detail=f"Downloaded archive missing {geo_name}"
                    )
                shutil.copy2(source, assets_path / geo_name)
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)

    return tag


def download_geo_files(files: List[Dict[str, str]]) -> List[str]:
    if not files:
        raise HTTPException(status_code=422, detail="files is required")
    _, assets_path = get_xray_paths()
    saved: List[str] = []
    assets_path.mkdir(parents=True, exist_ok=True)

    for entry in files:
        name = (entry.get("name") or "").strip()
        url = (entry.get("url") or "").strip()
        if not name or not url:
            raise HTTPException(status_code=422, detail="Each file must include name and url")

        dest = assets_path / name
        req = urllib.request.Request(url, headers={"User-Agent": "Rebecca-Maintenance-Service"})
        try:
            with urllib.request.urlopen(req, timeout=180) as resp, open(dest, "wb") as handle:
                shutil.copyfileobj(resp, handle)
        except Exception as exc:
            raise HTTPException(status_code=502, detail=f"Failed to download {name}: {exc}") from exc
        saved.append(str(dest))
    return saved


class SSLRequest(BaseModel):
    email: EmailStr
    domains: List[str]

    @field_validator("domains")
    @classmethod
    def validate_domains(cls, value: List[str]) -> List[str]:
        normalized: List[str] = []
        for domain in value:
            cleaned = domain.strip()
            if not cleaned:
                continue
            if not DOMAIN_PATTERN.match(cleaned):
                raise ValueError(f"Invalid domain: {domain}")
            normalized.append(cleaned)
        if not normalized:
            raise ValueError("At least one domain must be provided")
        return normalized


class SSLRenewRequest(BaseModel):
    domain: Optional[str] = None


class XrayUpdateRequest(BaseModel):
    version: Optional[str] = None


class GeoUpdateRequest(BaseModel):
    files: List[Dict[str, str]]


def load_env_file(env_path: Path) -> Dict[str, str]:
    env_values: Dict[str, str] = {}
    if not env_path.exists():
        return env_values
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env_values[key.strip()] = value.strip().strip('"').strip("'")
    return env_values


def run_subprocess(
    cmd: List[str],
    *,
    input_bytes: Optional[bytes] = None,
    cwd: Optional[Path] = None,
    check: bool = True,
) -> subprocess.CompletedProcess[bytes]:
    logger.info("Executing command: %s", " ".join(cmd))
    proc = subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        input=input_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and proc.returncode != 0:
        raise RuntimeError(
            f"Command {' '.join(cmd)} failed with exit code {proc.returncode}",
            proc.stdout.decode(errors="ignore"),
            proc.stderr.decode(errors="ignore"),
        )
    return proc


def run_rebecca_command(*args: str) -> subprocess.CompletedProcess[bytes]:
    if not settings.rebecca_cli.exists():
        raise RuntimeError(f"rebecca CLI not found at {settings.rebecca_cli}")
    cmd = [str(settings.rebecca_cli), *args]
    return run_subprocess(cmd)


def compose_command(*args: str, input_bytes: Optional[bytes] = None) -> subprocess.CompletedProcess[bytes]:
    if not settings.compose_file.exists():
        raise RuntimeError("docker-compose.yml was not found")
    return run_subprocess(settings.compose_cmd(*args), input_bytes=input_bytes)


def ensure_local_request(request: Request) -> None:
    host = request.client.host if request.client else None
    if host not in settings.allowed_hosts:
        raise HTTPException(status_code=403, detail="Only local requests are allowed")


def safe_extract_tar(archive: Path, destination: Path) -> None:
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar.getmembers():
            member_path = destination / member.name
            if not str(member_path.resolve()).startswith(str(destination.resolve())):
                raise HTTPException(status_code=400, detail="Unsafe archive detected")
        tar.extractall(destination)


def extract_backup_archive(archive: Path, destination: Path) -> None:
    """Extract backup archive (zip or tar.gz) to destination."""
    archive_name = archive.name.lower()
    suffix = archive.suffix.lower()
    
    # Check if it's a .tar.gz file (has .gz suffix but actually .tar.gz)
    is_tar_gz = archive_name.endswith(".tar.gz") or archive_name.endswith(".tgz")
    
    if suffix == ".zip" and not is_tar_gz:
        with zipfile.ZipFile(archive) as archive_file:
            for member in archive_file.namelist():
                member_path = Path(destination, member)
                resolved = member_path.resolve()
                if not str(resolved).startswith(str(destination.resolve())):
                    raise HTTPException(status_code=400, detail="Unsafe archive detected")
            archive_file.extractall(destination)
    else:
        # Handle .tar.gz, .tgz, or other tar formats
        safe_extract_tar(archive, destination)


def copy_directory(source: Path, destination: Path, excluded: Optional[List[Path]] = None) -> None:
    if not source.exists():
        return
    excluded = [path.resolve() for path in (excluded or [])]

    def _ignore(current: str, entries: List[str]) -> List[str]:
        ignored: List[str] = []
        for name in entries:
            full_path = (Path(current) / name).resolve()
            for excluded_path in excluded:
                excluded_str = str(excluded_path)
                full_str = str(full_path)
                if full_str == excluded_str or full_str.startswith(f"{excluded_str}{os.sep}"):
                    ignored.append(name)
                    break
        return ignored

    shutil.copytree(source, destination, dirs_exist_ok=True, ignore=_ignore)


def mysql_database_names(service: str, password: str) -> List[str]:
    if pymysql is None:
        raise HTTPException(
            status_code=500,
            detail="pymysql is not installed. Install it with: pip install pymysql"
        )
    try:
        conn = pymysql.connect(
            host="127.0.0.1",
            user="root",
            password=password,
            charset="utf8mb4",
            cursorclass=pymysql.cursors.Cursor,
        )
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Failed to connect to MySQL: {exc}") from exc
    try:
        with conn.cursor() as cursor:
            cursor.execute("SHOW DATABASES;")
            rows = cursor.fetchall()
    finally:
        conn.close()
    names = [row[0] for row in rows if row and row[0]]
    return [name for name in names if name not in MYSQL_DEFAULT_DATABASES]


def dump_mysql_databases(root: Path, env_values: Dict[str, str]) -> None:
    """
    Dump MySQL/MariaDB databases to SQL file.
    This function is safe to fail - backup will fall back to SQLite if needed.
    """
    if not settings.compose_file.exists():
        logger.info("docker-compose.yml not found, skipping MySQL dump")
        return

    try:
        compose_text = settings.compose_file.read_text()
    except Exception as exc:
        logger.warning("Failed to read docker-compose.yml: %s", exc)
        return

    service = detect_db_service(compose_text)
    if not service:
        logger.info("No MySQL/MariaDB service detected in docker-compose.yml")
        return

    password = env_values.get("MYSQL_ROOT_PASSWORD")
    if not password:
        logger.warning("MYSQL_ROOT_PASSWORD missing in .env, skipping MySQL dump")
        return

    try:
        compose_command("up", "-d", service)
        time.sleep(5)
    except RuntimeError as exc:
        logger.warning("Failed to start MySQL service: %s", exc)
        return

    try:
        databases = mysql_database_names(service, password)
    except HTTPException as exc:
        # pymysql not installed or connection failed
        logger.warning("Failed to connect to MySQL: %s", exc.detail)
        return
    except Exception as exc:
        logger.warning("Failed to list MySQL databases: %s", exc)
        return

    if not databases:
        logger.info("No MySQL databases found to dump")
        return

    dump_file = root / "db_backup.sql"
    try:
        cmd = settings.compose_cmd(
            "exec",
            "-T",
            service,
            "mysqldump",
            "-u",
            "root",
            f"-p{password}",
            "--events",
            "--triggers",
            "--routines",
            "--single-transaction",
            "--quick",
            "--databases",
            *databases,
        )
        with dump_file.open("wb") as handle:
            proc = subprocess.run(cmd, stdout=handle, stderr=subprocess.PIPE, timeout=300)
        if proc.returncode != 0:
            error_msg = proc.stderr.decode(errors='ignore')
            logger.warning("mysqldump failed (exit code %d): %s", proc.returncode, error_msg)
            # Don't raise - fallback to SQLite will handle it
            return
        logger.info("MySQL dump completed successfully: %d databases", len(databases))
    except subprocess.TimeoutExpired:
        logger.warning("mysqldump timed out after 300 seconds")
        return
    except Exception as exc:
        logger.warning("Failed to run mysqldump: %s", exc)
        return


def create_backup_archive(format: str = "zip") -> Path:
    """
    Create a backup archive containing all necessary files.
    
    Args:
        format: Archive format - "zip" or "tar.gz"
    
    Returns:
        Path to the created archive file
    """
    if format not in ("zip", "tar.gz"):
        raise ValueError(f"Unsupported archive format: {format}. Use 'zip' or 'tar.gz'")
    
    env_values = load_env_file(settings.env_file)
    
    # Create backup directory if it doesn't exist
    settings.backup_dir.mkdir(parents=True, exist_ok=True)
    
    # Generate backup filename with timestamp
    timestamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
    extension = ".zip" if format == "zip" else ".tar.gz"
    backup_filename = f"rebecca_backup_{timestamp}{extension}"
    archive_path = settings.backup_dir / backup_filename
    
    with tempfile.TemporaryDirectory() as temp_dir:
        root = Path(temp_dir) / "payload"
        root.mkdir(parents=True, exist_ok=True)

        # Copy configuration files
        if settings.env_file.exists():
            shutil.copy2(settings.env_file, root / ".env")
        if settings.compose_file.exists():
            shutil.copy2(settings.compose_file, root / "docker-compose.yml")

        # Copy data directory (excluding mysql)
        copy_directory(
            settings.data_dir,
            root / "rebecca_data",
            excluded=[settings.data_dir / "mysql"],
        )
        
        # Copy app directory
        copy_directory(settings.app_dir, root / "rebecca_app")

        # Dump MySQL/MariaDB databases
        try:
            dump_mysql_databases(root, env_values)
        except HTTPException:
            # Re-raise HTTP exceptions (user-facing errors)
            raise
        except RuntimeError as exc:
            # RuntimeError from compose_command or other runtime issues
            logger.exception("Failed to dump MySQL databases (runtime error): %s", exc)
            # Continue without MySQL dump - SQLite fallback will handle it
        except Exception as exc:
            # Catch any other exceptions and log them
            logger.exception("Failed to dump MySQL databases: %s", exc)
            # Continue without MySQL dump - SQLite fallback will handle it

        # Fallback to SQLite if MySQL dump doesn't exist
        if not (root / "db_backup.sql").exists():
            try:
                sqlite_path = resolve_sqlite_path(env_values)
            except HTTPException:
                sqlite_path = None
            if sqlite_path and sqlite_path.exists():
                shutil.copy2(sqlite_path, root / "db_backup.sqlite")

        # Create archive in backup_dir (not in temp_dir so it persists)
        if format == "zip":
            with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                for path in root.rglob("*"):
                    if path.is_file():
                        archive.write(path, path.relative_to(root))
        else:  # tar.gz
            with tarfile.open(archive_path, "w:gz") as archive:
                for path in root.rglob("*"):
                    if path.is_file():
                        archive.add(path, arcname=path.relative_to(root))

    logger.info(f"Backup archive created: {archive_path}")
    _cleanup_old_backups()
    return archive_path


def _cleanup_old_backups() -> None:
    if not settings.backup_dir.exists():
        return
    now = datetime.utcnow()
    cutoff = now - timedelta(days=BACKUP_RETENTION_DAYS)
    candidates = sorted(
        settings.backup_dir.glob("rebecca_backup_*"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    for index, path in enumerate(candidates):
        try:
            file_time = datetime.utcfromtimestamp(path.stat().st_mtime)
        except Exception:
            file_time = now
        if index >= BACKUP_MAX_FILES or file_time < cutoff:
            try:
                path.unlink(missing_ok=True)
                logger.info("Removed old backup archive: %s", path.name)
            except Exception as exc:
                logger.warning("Failed to remove old backup '%s': %s", path, exc)


def cleanup_file(path: Path) -> None:
    Path(path).unlink(missing_ok=True)


def stop_stack() -> None:
    compose_command("down")


def start_stack() -> None:
    compose_command("up", "-d", "--remove-orphans")


def detect_db_service(compose_content: str) -> Optional[str]:
    lowered = compose_content.lower()
    if "mariadb" in lowered:
        return "mariadb"
    if "mysql" in lowered:
        return "mysql"
    return None


def resolve_sqlite_path(env_values: Dict[str, str]) -> Path:
    url = env_values.get("SQLALCHEMY_DATABASE_URL", "")
    url = url.strip().strip('"').strip("'")
    if not url.startswith("sqlite"):
        raise HTTPException(status_code=400, detail="SQLite URL not detected in .env")
    path = url.split("sqlite://", 1)[-1]
    path = path.lstrip("/")
    sqlite_path = Path("/") / path
    return sqlite_path


def restore_sql_dump(dump_path: Path, env_values: Dict[str, str]) -> None:
    compose_text = settings.compose_file.read_text()
    service = detect_db_service(compose_text)
    if not service:
        raise HTTPException(status_code=400, detail="Database service not detected in compose file")

    password = env_values.get("MYSQL_ROOT_PASSWORD")
    if not password:
        raise HTTPException(status_code=400, detail="MYSQL_ROOT_PASSWORD missing in .env")

    compose_command("up", "-d", service)
    time.sleep(5)
    with dump_path.open("rb") as fh:
        compose_command(
            "exec",
            "-T",
            service,
            "mysql",
            "-u",
            "root",
            f"-p{password}",
            input_bytes=fh.read(),
        )


def restore_sqlite_backup(sqlite_backup: Path, env_values: Dict[str, str]) -> None:
    target_path = resolve_sqlite_path(env_values)
    target_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(sqlite_backup, target_path)


def restore_backup_archive(archive_path: Path) -> None:
    if not archive_path.exists():
        raise HTTPException(status_code=400, detail="Uploaded backup not found on disk")

    with tempfile.TemporaryDirectory() as temp_dir:
        extracted = Path(temp_dir) / "extracted"
        extracted.mkdir(parents=True, exist_ok=True)
        extract_backup_archive(archive_path, extracted)

        env_src = extracted / ".env"
        compose_src = extracted / "docker-compose.yml"
        data_src = extracted / "rebecca_data"
        app_src = extracted / "rebecca_app"
        sql_dump = extracted / "db_backup.sql"
        sqlite_dump = extracted / "db_backup.sqlite"

        if not env_src.exists() or not compose_src.exists():
            raise HTTPException(status_code=400, detail="Backup missing .env or docker-compose.yml")

        stop_stack()

        timestamp = datetime.utcnow().strftime("%Y%m%d%H%M%S")
        shutil.copy2(env_src, settings.env_file)
        shutil.copy2(compose_src, settings.compose_file)

        if data_src.exists():
            if settings.data_dir.exists():
                snapshot_dir = settings.data_dir.parent / f"{settings.data_dir.name}_pre_import_{timestamp}"
                if snapshot_dir.exists():
                    shutil.rmtree(snapshot_dir)
                shutil.move(settings.data_dir, snapshot_dir)
            shutil.copytree(data_src, settings.data_dir, dirs_exist_ok=True)

        if app_src.exists():
            if settings.app_dir.exists():
                app_snapshot = settings.app_dir.parent / f"{settings.app_dir.name}_pre_import_{timestamp}"
                if app_snapshot.exists():
                    shutil.rmtree(app_snapshot)
                shutil.move(settings.app_dir, app_snapshot)
            shutil.copytree(app_src, settings.app_dir, dirs_exist_ok=True)

        env_values = load_env_file(settings.env_file)

        if sql_dump.exists():
            restore_sql_dump(sql_dump, env_values)
        elif sqlite_dump.exists():
            restore_sqlite_backup(sqlite_dump, env_values)

        start_stack()


def send_backup_to_telegram(path: Path) -> None:
    env_values = load_env_file(settings.env_file)
    enabled = env_values.get("BACKUP_SERVICE_ENABLED", "").lower() == "true"
    bot_key = env_values.get("BACKUP_TELEGRAM_BOT_KEY")
    chat_id = env_values.get("BACKUP_TELEGRAM_CHAT_ID")
    topic_id = env_values.get("BACKUP_TELEGRAM_TOPIC_ID")
    if not enabled or not bot_key or not chat_id:
        return
    caption = f"Rebecca backup {path.name} at {datetime.utcnow().isoformat()} UTC"
    try:
        cmd = [
            "curl",
            "-s",
            "-F",
            f"chat_id={chat_id}",
            "-F",
            f"document=@{str(path)}",
            "-F",
            f"caption={caption}",
        ]
        if topic_id:
            cmd.extend(["-F", f"message_thread_id={topic_id}"])
        cmd.append(f"https://api.telegram.org/bot{bot_key}/sendDocument")
        run_subprocess(cmd, check=False)
    except Exception as exc:
        logger.error("Failed to send backup to Telegram: %s", exc)


def send_backup_to_telegram_with_config(
    path: Path,
    bot_key: Optional[str] = None,
    chat_id: Optional[str] = None,
    topic_id: Optional[str] = None,
) -> None:
    """Send backup to Telegram with provided config."""
    if not bot_key or not chat_id:
        logger.warning("Telegram config not provided, skipping backup send")
        return
    
    caption = f"Rebecca backup {path.name} at {datetime.utcnow().isoformat()} UTC"
    try:
        cmd = [
            "curl",
            "-s",
            "-F",
            f"chat_id={chat_id}",
            "-F",
            f"document=@{str(path)}",
            "-F",
            f"caption={caption}",
        ]
        if topic_id:
            cmd.extend(["-F", f"message_thread_id={topic_id}"])
        cmd.append(f"https://api.telegram.org/bot{bot_key}/sendDocument")
        run_subprocess(cmd, check=False)
        logger.info(f"Backup sent to Telegram: {path.name}")
    except Exception as exc:
        logger.error("Failed to send backup to Telegram: %s", exc)


async def trigger_rebecca_command(*args: str) -> Dict[str, str]:
    def _runner() -> Dict[str, str]:
        try:
            result = run_rebecca_command(*args)
            return {
                "status": "ok",
                "stdout": result.stdout.decode(errors="ignore"),
                "stderr": result.stderr.decode(errors="ignore"),
            }
        except RuntimeError as exc:
            message = exc.args[0]
            stdout = exc.args[1] if len(exc.args) > 1 else ""
            stderr = exc.args[2] if len(exc.args) > 2 else ""
            raise HTTPException(
                status_code=500,
                detail={"message": message, "stdout": stdout, "stderr": stderr},
            ) from exc

    return await asyncio.to_thread(_runner)


@app.middleware("http")
async def local_only(request: Request, call_next):
    try:
        ensure_local_request(request)
    except HTTPException as exc:
        return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail})
    return await call_next(request)


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "app_dir": str(settings.app_dir),
        "data_dir": str(settings.data_dir),
        "rebecca_cli": str(settings.rebecca_cli),
    }


@app.post("/update")
async def update_panel():
    result = await trigger_rebecca_command("update")
    return {"status": "ok", "stdout": result["stdout"].strip()}


@app.post("/restart")
async def restart_panel():
    result = await trigger_rebecca_command("restart", "-n")
    return {"status": "ok", "stdout": result["stdout"].strip()}


@app.post("/backup/export")
async def export_backup(background_tasks: BackgroundTasks, format: str = Query("zip", description="Archive format: 'zip' or 'tar.gz'")):
    """
    Export backup archive.
    
    Query Parameters:
        format: Archive format - "zip" (default) or "tar.gz"
    """
    format_lower = format.lower().strip()
    if format_lower not in ("zip", "tar.gz", "tar"):
        raise HTTPException(status_code=400, detail="Format must be 'zip' or 'tar.gz'")
    
    # Normalize tar -> tar.gz
    if format_lower == "tar":
        format_lower = "tar.gz"
    
    try:
        archive_path = await asyncio.to_thread(create_backup_archive, format_lower)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    
    # Determine media type based on format
    media_type = "application/zip" if format_lower == "zip" else "application/gzip"
    
    # Send to Telegram in background (don't wait for it)
    background_tasks.add_task(send_backup_to_telegram, archive_path)
    
    # Note: Archive is saved in backup_dir and will persist until manually deleted
    # For automatic cleanup, implement a cleanup task that removes old backups
    
    return FileResponse(
        archive_path,
        media_type=media_type,
        filename=archive_path.name,
        background=background_tasks,
    )


@app.post("/backup/import")
async def import_backup(file: UploadFile = File(...)):
    filename = file.filename or ""
    if not (filename.endswith(".tar.gz") or filename.endswith(".zip")):
        raise HTTPException(status_code=400, detail="Backup must be a .tar.gz or .zip archive")

    suffix = ".zip" if filename.endswith(".zip") else ".tar.gz"
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as temp_file:
        contents = await file.read()
        temp_file.write(contents)
        temp_path = Path(temp_file.name)

    try:
        await asyncio.to_thread(restore_backup_archive, temp_path)
    finally:
        temp_path.unlink(missing_ok=True)

    return {"status": "ok", "message": "Backup imported successfully"}


@app.post("/ssl/issue")
async def ssl_issue(request: SSLRequest):
    domains_arg = ",".join(request.domains)
    result = await trigger_rebecca_command(
        "ssl",
        "issue",
        f"--email={request.email}",
        f"--domains={domains_arg}",
        "--non-interactive",
    )
    return {"status": "ok", "stdout": result["stdout"].strip()}


@app.post("/ssl/renew")
async def ssl_renew(request: Optional[SSLRenewRequest] = None):
    cmd = ["ssl", "renew"]
    if request and request.domain:
        cmd.append(f"--domain={request.domain}")
    result = await trigger_rebecca_command(*cmd)
    return {"status": "ok", "stdout": result["stdout"].strip()}


@app.get("/version/panel")
async def panel_version():
    return get_service_image_info(settings.compose_file, settings.service_name)


@app.get("/version/node")
async def node_version():
    return get_service_image_info(settings.node_compose_file, settings.node_service_name)


@app.post("/xray/update-core")
async def update_xray_core(payload: Optional[XrayUpdateRequest] = None):
    tag = await asyncio.to_thread(
        install_xray_assets,
        payload.version if payload else None,
        True,
        True,
    )
    return {"status": "ok", "version": tag}


@app.post("/xray/update-geodata")
async def update_xray_geodata(payload: GeoUpdateRequest):
    saved = await asyncio.to_thread(download_geo_files, payload.files)
    return {"status": "ok", "files": saved}


@app.post("/backup/export-with-telegram")
async def export_backup_with_telegram(
    background_tasks: BackgroundTasks,
    telegram_config: dict = Body(...),
    format: str = Query("zip", description="Archive format: 'zip' or 'tar.gz'"),
):
    """
    Export backup archive and send to Telegram.
    
    Body Parameters:
        telegram_config: Dict with keys: bot_key (str), chat_id (str), topic_id (int, optional)
    
    Query Parameters:
        format: Archive format - "zip" (default) or "tar.gz"
    """
    format_lower = format.lower().strip()
    if format_lower not in ("zip", "tar.gz", "tar"):
        raise HTTPException(status_code=400, detail="Format must be 'zip' or 'tar.gz'")
    
    # Normalize tar -> tar.gz
    if format_lower == "tar":
        format_lower = "tar.gz"
    
    try:
        archive_path = await asyncio.to_thread(create_backup_archive, format_lower)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    
    # Send to Telegram in background with provided config
    bot_key = telegram_config.get("bot_key")
    chat_id = telegram_config.get("chat_id")
    topic_id = telegram_config.get("topic_id")
    
    background_tasks.add_task(
        send_backup_to_telegram_with_config,
        archive_path,
        bot_key,
        chat_id,
        str(topic_id) if topic_id else None,
    )
    
    # Determine media type based on format
    media_type = "application/zip" if format_lower == "zip" else "application/gzip"
    
    return FileResponse(
        path=str(archive_path),
        media_type=media_type,
        filename=archive_path.name,
        headers={
            "Content-Disposition": f'attachment; filename="{archive_path.name}"',
        },
        background=background_tasks,
    )


@app.post("/service/update")
async def update_service():
    try:
        req = urllib.request.Request(
            MAINT_SOURCE_URL,
            headers={"User-Agent": "Rebecca-Maintenance-Service"},
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            content = resp.read()
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"Failed to download service source: {exc}") from exc

    path = Path(__file__).resolve()
    tmp_path = path.with_suffix(".tmp")
    try:
        tmp_path.write_bytes(content)
        os.replace(tmp_path, path)
    finally:
        if tmp_path.exists():
            tmp_path.unlink(missing_ok=True)

    try:
        run_subprocess(["systemctl", "restart", MAINT_UNIT_NAME], check=False)
    except Exception as exc:
        logger.warning("Failed to restart maintenance service: %s", exc)

    return {"status": "ok", "message": "Service source updated, restart requested"}


def main():
    uvicorn.run(
        "main:app",
        host=settings.host,
        port=settings.port,
        reload=False,
    )


if __name__ == "__main__":
    main()
