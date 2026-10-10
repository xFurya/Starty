"""ICS-лента (RFC 5545) для подписки в системном календаре."""
import datetime as dt

VTZ = """BEGIN:VTIMEZONE
TZID:Europe/Moscow
BEGIN:STANDARD
DTSTART:19700101T000000
TZOFFSETFROM:+0300
TZOFFSETTO:+0300
TZNAME:MSK
END:STANDARD
END:VTIMEZONE"""


def _esc(s):
    return (s.replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,")
            .replace("\r\n", "\\n").replace("\n", "\\n"))


def _fold(line):
    """Строки длиннее 75 октетов переносятся (по UTF-8, не разрывая символы)."""
    out = []
    cur = b""
    for ch in line:
        b = ch.encode("utf-8")
        if len(cur) + len(b) > (75 if not out else 74):
            out.append(cur)
            cur = b""
        cur += b
    out.append(cur)
    return "\r\n ".join(x.decode("utf-8") for x in out)


def _local(t):
    return t.strftime("%Y%m%dT%H%M%S")


def _vevent(e, stamp, url, alarm=False):
    start = dt.datetime.fromisoformat(e["start"])
    end = dt.datetime.fromisoformat(e["end"])
    lines = [
        "BEGIN:VEVENT",
        f"UID:{e['id']}@starty",
        f"DTSTAMP:{stamp}",
        f"DTSTART;TZID=Europe/Moscow:{_local(start)}",
        f"DTEND;TZID=Europe/Moscow:{_local(end)}",
        "SUMMARY:" + _esc(e["title"]),
        "DESCRIPTION:" + _esc(e["desc"]),
    ]
    if e.get("venue"):
        lines.append("LOCATION:" + _esc(e["venue"]))
    if url:
        lines.append(f"URL:{url}#e={e['id']}")
    lines.append("TRANSP:TRANSPARENT")
    if alarm:
        lines += ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:" + _esc(e["title"]),
                  "TRIGGER:-PT15M", "END:VALARM"]
    lines.append("END:VEVENT")
    return lines


def single(e, generated, url=""):
    """Один старт с напоминанием за 15 минут — для кнопки «В календарь»."""
    stamp = generated.astimezone(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Starty//Календарь стартов//RU",
             "CALSCALE:GREGORIAN", "METHOD:PUBLISH"]
    lines += VTZ.split("\n")
    lines += _vevent(e, stamp, url, alarm=True)
    lines.append("END:VCALENDAR")
    return "\r\n".join(_fold(l) for l in lines) + "\r\n"


def build(events, generated, url=""):
    stamp = generated.astimezone(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    lines = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//Starty//Календарь стартов//RU",
        "CALSCALE:GREGORIAN",
        "METHOD:PUBLISH",
        "X-WR-CALNAME:Фигурное катание · старты",
        "X-WR-CALDESC:Старты по фигурному катанию: российские и международные с россиянами и белорусами. Время московское.",
        "X-WR-TIMEZONE:Europe/Moscow",
        "REFRESH-INTERVAL;VALUE=DURATION:PT6H",
        "X-PUBLISHED-TTL:PT6H",
    ]
    lines += VTZ.split("\n")
    for e in events:
        lines += _vevent(e, stamp, url)
    lines.append("END:VCALENDAR")
    return "\r\n".join(_fold(l) for l in lines) + "\r\n"
