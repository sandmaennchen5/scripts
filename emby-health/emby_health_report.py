#!/usr/bin/env python3
from __future__ import annotations

import configparser
import html
import json
import logging
import smtplib
import sqlite3
import ssl
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime
from email.message import EmailMessage
from pathlib import Path
from typing import Any, Iterable

import requests

VERSION = "2.1.0"


def as_bool(value: str | None, default: bool = False) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "ja", "on"}


def as_int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def csv_list(value: str) -> list[str]:
    return [part.strip().lower() for part in value.split(",") if part.strip()]


@dataclass
class Config:
    config_path: Path
    emby_url: str
    api_key: str
    user_id: str
    verify_tls: bool
    timeout: int
    page_size: int
    min_height: int
    german_aliases: list[str]
    check_subtitles: bool
    report_unknown_audio_language: bool
    report_unknown_resolution: bool
    metadata_mode: str
    html_language: str
    report_dir: Path
    database_path: Path
    keep_reports: int
    save_json: bool
    smtp_host: str
    smtp_port: int
    smtp_user: str
    smtp_password: str
    smtp_starttls: bool
    smtp_ssl: bool
    mail_from: str
    mail_to: list[str]
    subject_prefix: str
    attach_html: bool
    log_level: str
    log_file: Path | None

    @classmethod
    def load(cls, path: Path) -> "Config":
        parser = configparser.ConfigParser(interpolation=None)
        if not path.exists():
            raise RuntimeError(f"Konfigurationsdatei fehlt: {path}")
        parser.read(path, encoding="utf-8")
        base = path.parent.resolve()

        def get(section: str, key: str, fallback: str = "") -> str:
            return parser.get(section, key, fallback=fallback).strip()

        report_dir = Path(get("report", "directory", "reports"))
        database = Path(get("history", "database", "emby_health.sqlite3"))
        log_raw = get("logging", "file", "")

        if not report_dir.is_absolute():
            report_dir = base / report_dir
        if not database.is_absolute():
            database = base / database
        log_file = Path(log_raw) if log_raw else None
        if log_file and not log_file.is_absolute():
            log_file = base / log_file

        cfg = cls(
            config_path=path,
            emby_url=get("emby", "url").rstrip("/"),
            api_key=get("emby", "api_key"),
            user_id=get("emby", "user_id"),
            verify_tls=as_bool(get("emby", "verify_tls", "true"), True),
            timeout=as_int(get("emby", "timeout", "45"), 45),
            page_size=as_int(get("emby", "page_size", "500"), 500),
            min_height=as_int(get("checks", "minimum_height", "720"), 720),
            german_aliases=csv_list(
                get("checks", "german_language_aliases", "de,deu,ger,deutsch,german")
            ),
            check_subtitles=as_bool(
                get("checks", "check_german_subtitles", "true"), True
            ),
            report_unknown_audio_language=as_bool(
                get("checks", "report_unknown_audio_language", "true"), True
            ),
            report_unknown_resolution=as_bool(
                get("checks", "report_unknown_resolution", "true"), True
            ),
            metadata_mode=get("checks", "metadata_mode", "strict").lower(),
            html_language=get("report", "language", "de").lower(),
            report_dir=report_dir,
            database_path=database,
            keep_reports=as_int(get("report", "keep_reports", "20"), 20),
            save_json=as_bool(get("report", "save_json", "true"), True),
            smtp_host=get("mail", "smtp_host"),
            smtp_port=as_int(get("mail", "smtp_port", "25"), 25),
            smtp_user=get("mail", "smtp_user"),
            smtp_password=get("mail", "smtp_password"),
            smtp_starttls=as_bool(get("mail", "starttls", "false")),
            smtp_ssl=as_bool(get("mail", "ssl", "false")),
            mail_from=get("mail", "from"),
            mail_to=[x.strip() for x in get("mail", "to").split(",") if x.strip()],
            subject_prefix=get("mail", "subject_prefix", "[Emby Health]"),
            attach_html=as_bool(get("mail", "attach_html", "true"), True),
            log_level=get("logging", "level", "INFO").upper(),
            log_file=log_file,
        )
        cfg.validate()
        return cfg

    def validate(self) -> None:
        required = {
            "emby.url": self.emby_url,
            "emby.api_key": self.api_key,
            "mail.smtp_host": self.smtp_host,
            "mail.from": self.mail_from,
            "mail.to": ",".join(self.mail_to),
        }
        missing = [name for name, value in required.items() if not value]
        if missing:
            raise RuntimeError("Fehlende Konfiguration: " + ", ".join(missing))
        if self.smtp_ssl and self.smtp_starttls:
            raise RuntimeError("mail.ssl und mail.starttls dürfen nicht beide true sein.")
        if self.html_language not in {"de", "en"}:
            raise RuntimeError("report.language muss de oder en sein.")


def setup_logging(cfg: Config) -> None:
    handlers: list[logging.Handler] = [logging.StreamHandler(sys.stdout)]
    if cfg.log_file:
        cfg.log_file.parent.mkdir(parents=True, exist_ok=True)
        handlers.append(logging.FileHandler(cfg.log_file, encoding="utf-8"))
    logging.basicConfig(
        level=getattr(logging, cfg.log_level, logging.INFO),
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=handlers,
    )


class EmbyClient:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self.session = requests.Session()
        self.session.headers.update({
            "X-Emby-Token": cfg.api_key,
            "Accept": "application/json",
            "User-Agent": f"EmbyHealthReport/{VERSION}",
        })

    def get(self, path: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        response = self.session.get(
            f"{self.cfg.emby_url}{path}",
            params=params or {},
            timeout=self.cfg.timeout,
            verify=self.cfg.verify_tls,
        )
        response.raise_for_status()
        payload = response.json()
        if not isinstance(payload, dict):
            raise RuntimeError(f"Ungültige Antwort von {path}")
        return payload

    def paged(self, path: str, params: dict[str, Any]) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = []
        start = 0
        while True:
            query = dict(params)
            query.update({"StartIndex": start, "Limit": self.cfg.page_size})
            payload = self.get(path, query)
            batch = payload.get("Items", [])
            if not isinstance(batch, list):
                raise RuntimeError(f"Ungültige Items-Antwort von {path}")
            result.extend(x for x in batch if isinstance(x, dict))
            total = as_int(payload.get("TotalRecordCount"), len(result))
            start += len(batch)
            if not batch or start >= total:
                return result

    def missing_episodes(self) -> list[dict[str, Any]]:
        params: dict[str, Any] = {
            "Fields": "Overview,PremiereDate,Path,ProviderIds"
        }
        if self.cfg.user_id:
            params["UserId"] = self.cfg.user_id
        return self.paged("/Shows/Missing", params)

    def library_items(self) -> list[dict[str, Any]]:
        fields = ",".join([
            "MediaStreams", "MediaSources", "Overview", "Genres", "ProviderIds",
            "PremiereDate", "Path", "People", "Studios", "DateCreated",
            "ProductionYear", "ImageTags", "BackdropImageTags", "Size",
            "Bitrate", "Width", "Height", "Container"
        ])
        params = {
            "Recursive": "true",
            "IncludeItemTypes": "Movie,Episode",
            "Fields": fields,
            "EnableImages": "true",
            "EnableUserData": "false",
        }
        path = f"/Users/{self.cfg.user_id}/Items" if self.cfg.user_id else "/Items"
        return self.paged(path, params)


def media_streams(item: dict[str, Any]) -> list[dict[str, Any]]:
    streams: list[dict[str, Any]] = []
    if isinstance(item.get("MediaStreams"), list):
        streams.extend(x for x in item["MediaStreams"] if isinstance(x, dict))
    if isinstance(item.get("MediaSources"), list):
        for source in item["MediaSources"]:
            if isinstance(source, dict) and isinstance(source.get("MediaStreams"), list):
                streams.extend(x for x in source["MediaStreams"] if isinstance(x, dict))

    unique: list[dict[str, Any]] = []
    seen: set[tuple[Any, ...]] = set()
    for stream in streams:
        key = (
            stream.get("Type"), stream.get("Index"), stream.get("Codec"),
            stream.get("Language"), stream.get("Width"), stream.get("Height"),
            stream.get("Channels")
        )
        if key not in seen:
            seen.add(key)
            unique.append(stream)
    return unique


def streams_of(item: dict[str, Any], kind: str) -> list[dict[str, Any]]:
    return [s for s in media_streams(item)
            if str(s.get("Type", "")).lower() == kind.lower()]


def language_values(stream: dict[str, Any]) -> set[str]:
    keys = ("Language", "DisplayLanguage", "Title", "DisplayTitle")
    return {
        str(stream.get(key) or "").strip().lower()
        for key in keys if str(stream.get(key) or "").strip()
    }


def language_match(stream: dict[str, Any], aliases: Iterable[str]) -> bool:
    for value in language_values(stream):
        for alias in aliases:
            if (
                value == alias
                or value.startswith(alias + " ")
                or value.endswith(" " + alias)
                or f" {alias} " in value
            ):
                return True
    return False


def has_language(item: dict[str, Any], kind: str, aliases: list[str]) -> bool:
    return any(language_match(stream, aliases) for stream in streams_of(item, kind))


def display_name(item: dict[str, Any]) -> str:
    name = str(item.get("Name") or "Ohne Titel")
    if item.get("Type") == "Episode":
        series = str(item.get("SeriesName") or "Unbekannte Serie")
        season = as_int(item.get("ParentIndexNumber"), -1)
        episode = as_int(item.get("IndexNumber"), -1)
        code = f"S{season:02d}E{episode:02d}" if season >= 0 and episode >= 0 else "Episode"
        return f"{series} – {code} – {name}"
    year = as_int(item.get("ProductionYear"), 0)
    return f"{name} ({year})" if year else name


def best_video(item: dict[str, Any]) -> dict[str, Any] | None:
    videos = streams_of(item, "Video")
    if not videos:
        return None
    return max(videos, key=lambda s: as_int(s.get("Width")) * as_int(s.get("Height")))


def resolution(item: dict[str, Any]) -> tuple[int, int]:
    stream = best_video(item)
    if stream:
        return as_int(stream.get("Width")), as_int(stream.get("Height"))
    return as_int(item.get("Width")), as_int(item.get("Height"))


def resolution_bucket(height: int) -> str:
    if height >= 2160:
        return "4K"
    if height >= 1080:
        return "1080p"
    if height >= 720:
        return "720p"
    if height > 0:
        return "SD"
    return "Unbekannt"


def metadata_missing(item: dict[str, Any]) -> list[str]:
    checks = [
        ("Beschreibung", bool(str(item.get("Overview") or "").strip())),
        ("Jahr/Datum", bool(item.get("ProductionYear") or item.get("PremiereDate"))),
        ("Genres", bool(item.get("Genres"))),
        ("Provider-ID", bool(item.get("ProviderIds"))),
        ("Poster", bool((item.get("ImageTags") or {}).get("Primary"))),
        ("Hintergrundbild", bool(item.get("BackdropImageTags"))),
        ("Personen", bool(item.get("People"))),
    ]
    return [label for label, present in checks if not present]


def is_no_metadata(item: dict[str, Any], mode: str) -> bool:
    missing = set(metadata_missing(item))
    if mode == "any":
        return bool(missing)
    core = {"Beschreibung", "Jahr/Datum", "Genres", "Provider-ID", "Poster"}
    return core.issubset(missing)


def codec_of(item: dict[str, Any], kind: str) -> str:
    streams = streams_of(item, kind)
    return str(streams[0].get("Codec") or "unbekannt").lower() if streams else "unbekannt"


def audio_languages(item: dict[str, Any]) -> str:
    values: set[str] = set()
    for stream in streams_of(item, "Audio"):
        langs = language_values(stream)
        values.add(sorted(langs)[0] if langs else "unbekannt")
    return ", ".join(sorted(values)) if values else "keine Audiospur erkannt"


@dataclass
class Findings:
    total_movies: int = 0
    total_episodes: int = 0
    total_bytes: int = 0
    resolution_counts: Counter = field(default_factory=Counter)
    video_codecs: Counter = field(default_factory=Counter)
    audio_codecs: Counter = field(default_factory=Counter)
    missing_episodes: list[dict[str, Any]] = field(default_factory=list)
    missing_seasons: list[dict[str, Any]] = field(default_factory=list)
    no_german_audio: list[dict[str, Any]] = field(default_factory=list)
    no_german_subtitles: list[dict[str, Any]] = field(default_factory=list)
    no_metadata: list[dict[str, Any]] = field(default_factory=list)
    low_resolution: list[dict[str, Any]] = field(default_factory=list)
    unknown_resolution: list[dict[str, Any]] = field(default_factory=list)
    unknown_audio_language: list[dict[str, Any]] = field(default_factory=list)
    duplicate_movies: list[dict[str, Any]] = field(default_factory=list)
    duplicate_episodes: list[dict[str, Any]] = field(default_factory=list)

    @property
    def total_findings(self) -> int:
        return sum(len(group) for group in [
            self.missing_episodes, self.missing_seasons, self.no_german_audio,
            self.no_german_subtitles, self.no_metadata, self.low_resolution,
            self.unknown_resolution, self.unknown_audio_language,
            self.duplicate_movies, self.duplicate_episodes
        ])


def analyze(cfg: Config, items: list[dict[str, Any]],
            missing: list[dict[str, Any]]) -> Findings:
    result = Findings(missing_episodes=missing)
    existing_seasons: set[tuple[str, int]] = set()
    movie_keys: defaultdict[tuple[str, int], list[dict[str, Any]]] = defaultdict(list)
    episode_keys: defaultdict[tuple[str, int, int], list[dict[str, Any]]] = defaultdict(list)

    for item in items:
        if item.get("Type") == "Movie":
            result.total_movies += 1
            movie_keys[
                (str(item.get("Name") or "").casefold(),
                 as_int(item.get("ProductionYear"), 0))
            ].append(item)
        elif item.get("Type") == "Episode":
            result.total_episodes += 1
            series = str(item.get("SeriesName") or "")
            season = as_int(item.get("ParentIndexNumber"), -1)
            episode = as_int(item.get("IndexNumber"), -1)
            if series and season >= 0:
                existing_seasons.add((series, season))
            episode_keys[(series.casefold(), season, episode)].append(item)

        result.total_bytes += as_int(item.get("Size"), 0)
        _, height = resolution(item)
        result.resolution_counts[resolution_bucket(height)] += 1
        result.video_codecs[codec_of(item, "Video")] += 1
        for stream in streams_of(item, "Audio"):
            result.audio_codecs[str(stream.get("Codec") or "unbekannt").lower()] += 1

        audio = streams_of(item, "Audio")
        if not has_language(item, "Audio", cfg.german_aliases):
            result.no_german_audio.append(item)
        if cfg.check_subtitles and not has_language(item, "Subtitle", cfg.german_aliases):
            result.no_german_subtitles.append(item)
        if cfg.report_unknown_audio_language and audio and all(
            not language_values(stream) for stream in audio
        ):
            result.unknown_audio_language.append(item)
        if is_no_metadata(item, cfg.metadata_mode):
            result.no_metadata.append(item)
        if height and height < cfg.min_height:
            result.low_resolution.append(item)
        elif cfg.report_unknown_resolution and not height:
            result.unknown_resolution.append(item)

    for values in movie_keys.values():
        if len(values) > 1:
            result.duplicate_movies.extend(values)
    for (series, season, episode), values in episode_keys.items():
        if len(values) > 1 and series and season >= 0 and episode >= 0:
            result.duplicate_episodes.extend(values)

    grouped: defaultdict[tuple[str, int], list[dict[str, Any]]] = defaultdict(list)
    for item in missing:
        series = str(item.get("SeriesName") or "Unbekannte Serie")
        season = as_int(item.get("ParentIndexNumber"), -1)
        if season >= 0:
            grouped[(series, season)].append(item)

    for (series, season), episodes in grouped.items():
        if (series, season) not in existing_seasons:
            result.missing_seasons.append({
                "SeriesName": series,
                "SeasonNumber": season,
                "EpisodeCount": len(episodes),
            })
    return result


def human_size(value: int) -> str:
    size = float(value)
    for unit in ("B", "KB", "MB", "GB", "TB", "PB"):
        if size < 1024 or unit == "PB":
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{value} B"


def esc(value: Any) -> str:
    return html.escape(str(value if value is not None else ""))


TRANSLATIONS = {
    "de": {
        "no_hits": "Keine Treffer.", "movies": "Filme", "unknown_series": "Unbekannte Serie",
        "episode": "Folge", "episodes": "Episoden", "season": "Staffel", "unknown_season": "Staffel unbekannt",
        "title": "Titel", "details": "Details", "path": "Pfad", "library_overview": "Bibliotheksübersicht",
        "resolutions": "Auflösungen", "video_codecs": "Video-Codecs", "audio_codecs": "Audio-Codecs",
        "missing_seasons": "Fehlende Staffeln", "missing_episodes": "Fehlende Episoden",
        "no_german_audio": "Ohne deutsche Audiospur", "no_german_subtitles": "Ohne deutsche Untertitel",
        "no_metadata": "Ohne Metadaten", "below": "Unter {height}p", "unknown_resolution": "Auflösung unbekannt",
        "unknown_audio": "Audiosprache unbekannt", "duplicate_movies": "Doppelte Filme",
        "duplicate_episodes": "Doppelte Episoden", "series": "Serie", "reported_episodes": "Folgen",
        "no_missing_seasons": "Keine komplett fehlenden Staffeln erkannt.", "since_last": "seit letztem Lauf",
        "audio": "Audio", "no_german_subtitle_detail": "Keine deutsche Untertitelspur erkannt",
        "missing": "Fehlt", "no_resolution": "Keine Auflösung von Emby geliefert",
        "same_movie": "Gleicher Titel und gleiches Jahr", "same_episode": "Gleiche Serie, Staffel und Episodennummer",
        "created_by": "Erstellt von", "unknown_title": "Ohne Titel"
    },
    "en": {
        "no_hits": "No findings.", "movies": "Movies", "unknown_series": "Unknown series",
        "episode": "Episode", "episodes": "Episodes", "season": "Season", "unknown_season": "Unknown season",
        "title": "Title", "details": "Details", "path": "Path", "library_overview": "Library overview",
        "resolutions": "Resolutions", "video_codecs": "Video codecs", "audio_codecs": "Audio codecs",
        "missing_seasons": "Missing seasons", "missing_episodes": "Missing episodes",
        "no_german_audio": "No German audio track", "no_german_subtitles": "No German subtitles",
        "no_metadata": "Missing metadata", "below": "Below {height}p", "unknown_resolution": "Unknown resolution",
        "unknown_audio": "Unknown audio language", "duplicate_movies": "Duplicate movies",
        "duplicate_episodes": "Duplicate episodes", "series": "Series", "reported_episodes": "Episodes",
        "no_missing_seasons": "No completely missing seasons detected.", "since_last": "since previous run",
        "audio": "Audio", "no_german_subtitle_detail": "No German subtitle track detected",
        "missing": "Missing", "no_resolution": "No resolution supplied by Emby",
        "same_movie": "Same title and production year", "same_episode": "Same series, season and episode number",
        "created_by": "Created by", "unknown_title": "Untitled"
    },
}


def tr(cfg: Config, key: str, **kwargs: Any) -> str:
    return TRANSLATIONS[cfg.html_language].get(key, key).format(**kwargs)


def item_rows(cfg: Config, items: list[dict[str, Any]], detail_fn) -> str:
    if not items:
        return f"<p class='ok'>{esc(tr(cfg, 'no_hits'))}</p>"
    movies = [item for item in items if item.get("Type") == "Movie"]
    episodes = [item for item in items if item.get("Type") == "Episode"]
    parts: list[str] = []
    if movies:
        rows = []
        for item in sorted(movies, key=lambda x: display_name(x).casefold()):
            rows.append("<tr>" f"<td>{esc(display_name(item))}</td>" f"<td>{esc(detail_fn(item))}</td>" f"<td class='path'>{esc(item.get('Path') or '–')}</td>" "</tr>")
        parts.append("<details class='media-group' open><summary>" + esc(tr(cfg, "movies")) + f" <span class='count'>{len(movies)}</span></summary>" + f"<table><thead><tr><th>{esc(tr(cfg, 'title'))}</th><th>{esc(tr(cfg, 'details'))}</th><th>{esc(tr(cfg, 'path'))}</th></tr></thead><tbody>" + "".join(rows) + "</tbody></table></details>")
    grouped: defaultdict[str, defaultdict[int, list[dict[str, Any]]]] = defaultdict(lambda: defaultdict(list))
    for item in episodes:
        grouped[str(item.get("SeriesName") or tr(cfg, "unknown_series"))][as_int(item.get("ParentIndexNumber"), -1)].append(item)
    for series in sorted(grouped, key=str.casefold):
        season_blocks = []
        series_count = sum(len(values) for values in grouped[series].values())
        for season in sorted(grouped[series]):
            season_items = sorted(grouped[series][season], key=lambda x: (as_int(x.get("IndexNumber"), 999999), str(x.get("Name") or "").casefold()))
            rows = []
            for item in season_items:
                episode = as_int(item.get("IndexNumber"), -1)
                episode_label = f"E{episode:02d}" if episode >= 0 else tr(cfg, "episode")
                rows.append("<tr>" f"<td>{esc(episode_label)}</td>" f"<td>{esc(item.get('Name') or tr(cfg, 'unknown_title'))}</td>" f"<td>{esc(detail_fn(item))}</td>" f"<td class='path'>{esc(item.get('Path') or '–')}</td>" "</tr>")
            season_label = f"{tr(cfg, 'season')} {season}" if season >= 0 else tr(cfg, "unknown_season")
            season_blocks.append("<details class='season-group'><summary>" f"{esc(season_label)} <span class='count'>{len(season_items)}</span></summary>" f"<table><thead><tr><th>{esc(tr(cfg, 'episode'))}</th><th>{esc(tr(cfg, 'title'))}</th><th>{esc(tr(cfg, 'details'))}</th><th>{esc(tr(cfg, 'path'))}</th></tr></thead><tbody>" + "".join(rows) + "</tbody></table></details>")
        parts.append("<details class='series-group'><summary>" f"{esc(series)} <span class='count'>{series_count}</span></summary>" + "".join(season_blocks) + "</details>")
    return "".join(parts)


def snapshot_counts(cfg: Config, findings: Findings) -> dict[str, int]:
    return {
        tr(cfg, "missing_seasons"): len(findings.missing_seasons), tr(cfg, "missing_episodes"): len(findings.missing_episodes),
        tr(cfg, "no_german_audio"): len(findings.no_german_audio), tr(cfg, "no_german_subtitles"): len(findings.no_german_subtitles),
        tr(cfg, "no_metadata"): len(findings.no_metadata), tr(cfg, "below", height=cfg.min_height): len(findings.low_resolution),
        tr(cfg, "unknown_resolution"): len(findings.unknown_resolution), tr(cfg, "unknown_audio"): len(findings.unknown_audio_language),
        tr(cfg, "duplicate_movies"): len(findings.duplicate_movies), tr(cfg, "duplicate_episodes"): len(findings.duplicate_episodes),
    }


def render_html(cfg: Config, findings: Findings, generated: datetime, previous: dict[str, int] | None) -> str:
    counts = snapshot_counts(cfg, findings)
    cards = []
    for label, count in counts.items():
        css = "ok-card" if count == 0 else ("warn-card" if count < 10 else "bad-card")
        delta = ""
        if previous and label in previous:
            difference = count - previous[label]
            if difference:
                delta = f"<small>{'+' if difference > 0 else ''}{difference} {esc(tr(cfg, 'since_last'))}</small>"
        cards.append(f"<div class='card {css}'><span>{esc(label)}</span><strong>{count}</strong>{delta}</div>")
    if findings.missing_seasons:
        missing_seasons = f"<table><thead><tr><th>{esc(tr(cfg, 'series'))}</th><th>{esc(tr(cfg, 'season'))}</th><th>{esc(tr(cfg, 'reported_episodes'))}</th></tr></thead><tbody>" + "".join(f"<tr><td>{esc(x['SeriesName'])}</td><td>{x['SeasonNumber']}</td><td>{x['EpisodeCount']}</td></tr>" for x in sorted(findings.missing_seasons, key=lambda x: (x['SeriesName'].casefold(), x['SeasonNumber']))) + "</tbody></table>"
    else:
        missing_seasons = f"<p class='ok'>{esc(tr(cfg, 'no_missing_seasons'))}</p>"
    resolution_items = "".join(f"<li><span>{esc(k)}</span><strong>{v}</strong></li>" for k, v in findings.resolution_counts.most_common())
    video_codecs = "".join(f"<li><span>{esc(k)}</span><strong>{v}</strong></li>" for k, v in findings.video_codecs.most_common(10))
    audio_codecs = "".join(f"<li><span>{esc(k)}</span><strong>{v}</strong></li>" for k, v in findings.audio_codecs.most_common(10))
    return f'''<!doctype html><html lang="{cfg.html_language}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Emby Health Report</title>
<style>body{{font-family:Arial,sans-serif;background:#f4f6f8;color:#17202a;margin:0}}.wrap{{max-width:1200px;margin:auto;padding:24px}}header{{background:#202a34;color:white;padding:28px;border-radius:12px}}header h1{{margin:0 0 8px}}.muted{{color:#64748b}}header .muted{{color:#cbd5e1}}.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(185px,1fr));gap:12px;margin:18px 0}}.card{{background:white;border-radius:10px;padding:16px;border-left:6px solid #94a3b8;box-shadow:0 2px 8px rgba(0,0,0,.06)}}.card span{{display:block;font-size:13px}}.card strong{{font-size:30px;display:block;margin-top:5px}}.card small{{font-size:11px}}.ok-card{{border-color:#22c55e}}.warn-card{{border-color:#f59e0b}}.bad-card{{border-color:#ef4444}}section{{background:white;margin:16px 0;padding:20px;border-radius:12px;box-shadow:0 2px 8px rgba(0,0,0,.05)}}table{{width:100%;border-collapse:collapse;font-size:13px}}th{{background:#e9eef3;text-align:left}}th,td{{padding:9px;border-bottom:1px solid #e5e7eb;vertical-align:top}}.path{{font-size:11px;word-break:break-all}}.ok{{color:#15803d;font-weight:bold}}ul.stats{{padding:0;list-style:none}}ul.stats li{{display:flex;justify-content:space-between;border-bottom:1px solid #eee;padding:7px}}.columns{{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:16px}}details{{margin:10px 0}}summary{{cursor:pointer;user-select:none}}.series-group>summary{{font-size:16px;font-weight:bold;background:#e8eef5;padding:11px;border-radius:8px}}.season-group{{margin-left:18px}}.season-group>summary{{font-weight:bold;background:#f5f7fa;padding:9px;border-radius:7px}}.media-group>summary{{font-size:16px;font-weight:bold;background:#e8eef5;padding:11px;border-radius:8px}}.count{{display:inline-block;min-width:22px;padding:2px 7px;margin-left:6px;border-radius:12px;background:#334155;color:white;font-size:11px;text-align:center}}footer{{text-align:center;color:#64748b;font-size:12px;padding:20px}}</style></head><body><div class="wrap">
<header><h1>Emby Health Report</h1><p class="muted">Version {VERSION} · {esc(generated.strftime("%d.%m.%Y %H:%M %Z"))}</p><p>{findings.total_movies} {esc(tr(cfg, 'movies'))} · {findings.total_episodes} {esc(tr(cfg, 'episodes'))} · {human_size(findings.total_bytes)}</p></header><div class="grid">{''.join(cards)}</div>
<section><h2>{esc(tr(cfg, 'library_overview'))}</h2><div class="columns"><div><h3>{esc(tr(cfg, 'resolutions'))}</h3><ul class="stats">{resolution_items}</ul></div><div><h3>{esc(tr(cfg, 'video_codecs'))}</h3><ul class="stats">{video_codecs}</ul></div><div><h3>{esc(tr(cfg, 'audio_codecs'))}</h3><ul class="stats">{audio_codecs}</ul></div></div></section>
<section><h2>1. {esc(tr(cfg, 'missing_seasons'))}</h2>{missing_seasons}</section><section><h2>2. {esc(tr(cfg, 'missing_episodes'))}</h2>{item_rows(cfg, findings.missing_episodes, lambda x: display_name(x))}</section><section><h2>3. {esc(tr(cfg, 'no_german_audio'))}</h2>{item_rows(cfg, findings.no_german_audio, lambda x: tr(cfg, 'audio') + ': ' + audio_languages(x))}</section><section><h2>4. {esc(tr(cfg, 'no_german_subtitles'))}</h2>{item_rows(cfg, findings.no_german_subtitles, lambda x: tr(cfg, 'no_german_subtitle_detail'))}</section><section><h2>5. {esc(tr(cfg, 'no_metadata'))}</h2>{item_rows(cfg, findings.no_metadata, lambda x: tr(cfg, 'missing') + ': ' + ', '.join(metadata_missing(x)))}</section><section><h2>6. {esc(tr(cfg, 'below', height=cfg.min_height))}</h2>{item_rows(cfg, findings.low_resolution, lambda x: f"{resolution(x)[0]}×{resolution(x)[1]}")}</section><section><h2>7. {esc(tr(cfg, 'unknown_resolution'))}</h2>{item_rows(cfg, findings.unknown_resolution, lambda x: tr(cfg, 'no_resolution'))}</section><section><h2>8. {esc(tr(cfg, 'unknown_audio'))}</h2>{item_rows(cfg, findings.unknown_audio_language, lambda x: audio_languages(x))}</section><section><h2>9. {esc(tr(cfg, 'duplicate_movies'))}</h2>{item_rows(cfg, findings.duplicate_movies, lambda x: tr(cfg, 'same_movie'))}</section><section><h2>10. {esc(tr(cfg, 'duplicate_episodes'))}</h2>{item_rows(cfg, findings.duplicate_episodes, lambda x: tr(cfg, 'same_episode'))}</section><footer>{esc(tr(cfg, 'created_by'))} Emby Health Report {VERSION}</footer></div></body></html>'''


class History:
    def __init__(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path)
        self.db.execute("""
            CREATE TABLE IF NOT EXISTS runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at TEXT NOT NULL,
                total_movies INTEGER NOT NULL,
                total_episodes INTEGER NOT NULL,
                total_bytes INTEGER NOT NULL,
                counts_json TEXT NOT NULL
            )
        """)
        self.db.commit()

    def previous_counts(self) -> dict[str, int] | None:
        row = self.db.execute(
            "SELECT counts_json FROM runs ORDER BY id DESC LIMIT 1"
        ).fetchone()
        return json.loads(row[0]) if row else None

    def save(self, generated: datetime, findings: Findings,
             counts: dict[str, int]) -> None:
        self.db.execute(
            "INSERT INTO runs(created_at,total_movies,total_episodes,total_bytes,counts_json) "
            "VALUES(?,?,?,?,?)",
            (
                generated.isoformat(), findings.total_movies, findings.total_episodes,
                findings.total_bytes, json.dumps(counts, ensure_ascii=False)
            ),
        )
        self.db.commit()

    def close(self) -> None:
        self.db.close()


def plain_summary(cfg: Config, findings: Findings, generated: datetime) -> str:
    lines = [
        "Emby Health Report",
        f"Erstellt: {generated.strftime('%d.%m.%Y %H:%M %Z')}",
        "",
        f"Filme: {findings.total_movies}",
        f"Episoden: {findings.total_episodes}",
        f"Erfasste Größe: {human_size(findings.total_bytes)}",
        "",
    ]
    lines.extend(f"{key}: {value}" for key, value in snapshot_counts(cfg, findings).items())
    return "\n".join(lines)


def send_mail(cfg: Config, subject: str, plain: str,
              report_html: str, report_path: Path) -> None:
    message = EmailMessage()
    message["From"] = cfg.mail_from
    message["To"] = ", ".join(cfg.mail_to)
    message["Subject"] = subject
    message.set_content(plain)
    message.add_alternative(report_html, subtype="html")

    if cfg.attach_html:
        message.add_attachment(
            report_path.read_bytes(),
            maintype="text",
            subtype="html",
            filename=report_path.name,
        )

    context = ssl.create_default_context()
    if cfg.smtp_ssl:
        with smtplib.SMTP_SSL(
            cfg.smtp_host, cfg.smtp_port, context=context, timeout=30
        ) as smtp:
            if cfg.smtp_user:
                smtp.login(cfg.smtp_user, cfg.smtp_password)
            smtp.send_message(message)
    else:
        with smtplib.SMTP(cfg.smtp_host, cfg.smtp_port, timeout=30) as smtp:
            smtp.ehlo()
            if cfg.smtp_starttls:
                smtp.starttls(context=context)
                smtp.ehlo()
            if cfg.smtp_user:
                smtp.login(cfg.smtp_user, cfg.smtp_password)
            smtp.send_message(message)


def rotate_reports(directory: Path, keep: int) -> None:
    if keep <= 0:
        return
    reports = sorted(
        directory.glob("emby-health-*.html"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    for old in reports[keep:]:
        old.unlink(missing_ok=True)
        old.with_suffix(".json").unlink(missing_ok=True)


def export_json(cfg: Config, findings: Findings, generated: datetime) -> dict[str, Any]:
    def compact(item: dict[str, Any]) -> dict[str, Any]:
        width, height = resolution(item)
        return {
            "type": item.get("Type"),
            "name": display_name(item),
            "path": item.get("Path"),
            "resolution": f"{width}x{height}" if width and height else None,
        }

    return {
        "version": VERSION,
        "generated_at": generated.isoformat(),
        "summary": snapshot_counts(cfg, findings),
        "library": {
            "movies": findings.total_movies,
            "episodes": findings.total_episodes,
            "bytes": findings.total_bytes,
            "resolutions": dict(findings.resolution_counts),
            "video_codecs": dict(findings.video_codecs),
            "audio_codecs": dict(findings.audio_codecs),
        },
        "findings": {
            "missing_seasons": findings.missing_seasons,
            "missing_episodes": [compact(x) for x in findings.missing_episodes],
            "no_german_audio": [compact(x) for x in findings.no_german_audio],
            "no_german_subtitles": [compact(x) for x in findings.no_german_subtitles],
            "no_metadata": [compact(x) for x in findings.no_metadata],
            "low_resolution": [compact(x) for x in findings.low_resolution],
            "unknown_resolution": [compact(x) for x in findings.unknown_resolution],
            "unknown_audio_language": [compact(x) for x in findings.unknown_audio_language],
            "duplicate_movies": [compact(x) for x in findings.duplicate_movies],
            "duplicate_episodes": [compact(x) for x in findings.duplicate_episodes],
        },
    }


def main() -> int:
    config_path = Path(sys.argv[1] if len(sys.argv) > 1 else "config.ini").resolve()
    try:
        cfg = Config.load(config_path)
        setup_logging(cfg)
        log = logging.getLogger("emby-health")
        log.info("Emby Health Report %s startet", VERSION)

        cfg.report_dir.mkdir(parents=True, exist_ok=True)
        generated = datetime.now().astimezone()
        client = EmbyClient(cfg)

        log.info("Lade fehlende Episoden ...")
        missing = client.missing_episodes()
        log.info("Lade Filme und Episoden einschließlich Mediendaten ...")
        items = client.library_items()
        log.info("%s Medien und %s fehlende Episoden geladen", len(items), len(missing))

        findings = analyze(cfg, items, missing)
        history = History(cfg.database_path)
        try:
            previous = history.previous_counts()
            report_html = render_html(cfg, findings, generated, previous)
            history.save(generated, findings, snapshot_counts(cfg, findings))
        finally:
            history.close()

        stamp = generated.strftime("%Y-%m-%d_%H-%M-%S")
        report_path = cfg.report_dir / f"emby-health-{stamp}.html"
        report_path.write_text(report_html, encoding="utf-8")
        (cfg.report_dir / "report-latest.html").write_text(report_html, encoding="utf-8")

        if cfg.save_json:
            report_path.with_suffix(".json").write_text(
                json.dumps(export_json(cfg, findings, generated),
                           ensure_ascii=False, indent=2),
                encoding="utf-8",
            )

        subject = (
            f"{cfg.subject_prefix} {findings.total_findings} Auffälligkeit(en) – "
            f"{generated.strftime('%d.%m.%Y')}"
        )
        log.info("Versende Bericht an %s", ", ".join(cfg.mail_to))
        send_mail(
            cfg,
            subject,
            plain_summary(cfg, findings, generated),
            report_html,
            report_path,
        )

        rotate_reports(cfg.report_dir, cfg.keep_reports)
        log.info("Fertig. Bericht: %s", report_path)
        return 0

    except requests.RequestException as exc:
        logging.exception("Emby-API-Fehler: %s", exc)
        return 2
    except (RuntimeError, OSError, ValueError, sqlite3.Error,
            smtplib.SMTPException) as exc:
        logging.exception("Fehler: %s", exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
