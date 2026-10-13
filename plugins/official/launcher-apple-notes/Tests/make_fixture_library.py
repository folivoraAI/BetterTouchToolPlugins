#!/usr/bin/env python3
"""Builds a small synthetic Notes library for end-to-end tests and screenshots.

Usage: make_fixture_library.py <fake-home>

Creates <fake-home>/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite
with the subset of Notes' Core Data schema the plugin reads. The plugin finds
it when the host runs with CFFIXED_USER_HOME=<fake-home>. All content is made up.
"""
from pathlib import Path
import gzip
import sqlite3
import subprocess
import sys
import time
import uuid

CORE_DATA_EPOCH = 978307200


def varint(value):
    out = bytearray()
    value &= (1 << 64) - 1
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def fld(number, payload):
    return varint(number << 3 | 2) + varint(len(payload)) + payload


def fint(number, value):
    return varint(number << 3) + varint(value)


def fstr(number, text):
    return fld(number, text.encode("utf-8"))


def note_data(runs):
    """runs: (text, options) tuples. Options: style, indent, checked, weight, link, attachment."""
    text = "".join(run for run, _ in runs)
    note = fstr(2, text)
    for run, options in runs:
        body = fint(1, len(run.encode("utf-16-le")) // 2)
        if "style" in options:
            paragraph = fint(1, options["style"])
            if "indent" in options:
                paragraph += fint(4, options["indent"])
            if "checked" in options:
                paragraph += fld(5, fld(1, uuid.uuid4().bytes) + fint(2, 1 if options["checked"] else 0))
            body += fld(2, paragraph)
        if "weight" in options:
            body += fint(5, options["weight"])
        if "link" in options:
            body += fstr(9, options["link"])
        if "attachment" in options:
            identifier, uti = options["attachment"]
            body += fld(12, fstr(1, identifier) + fstr(2, uti))
        note += fld(5, body)
    document = fint(2, 0) + fld(3, note)
    return gzip.compress(fint(1, 0) + fld(2, document))


def table_data(rows):
    """Minimal CRDT table document in the shape Notes writes."""
    keys = ["crRows", "crColumns", "cellColumns", "UUIDIndex", "self"]
    types = ["com.apple.notes.ICTable", "com.apple.CRDT.NSUUID", "com.apple.CRDT.NSString"]
    row_uuids = [uuid.uuid4().bytes for _ in rows]
    column_uuids = [uuid.uuid4().bytes for _ in rows[0]]
    uuids = row_uuids + column_uuids
    entries = [b""]

    def add(entry):
        entries.append(entry)
        return len(entries) - 1

    def reference(index):
        return fint(6, index)

    def uuid_reference(uuid_index):
        return add(fld(13, fint(1, 1) + fld(3, fint(1, 3) + fld(2, fint(2, uuid_index)))))

    def ordered_set(items):
        array = b"".join(fld(2, fint(1, index) + fld(2, item)) for index, item in enumerate(items))
        return add(fld(16, fld(1, fld(1, array) + fld(2, b"")) + fld(2, b"")))

    rows_entry = ordered_set(row_uuids)
    columns_entry = ordered_set(column_uuids)
    columns = b""
    for column in range(len(column_uuids)):
        cells = b""
        for row in range(len(row_uuids)):
            cell = add(fld(10, fstr(2, rows[row][column])))
            cells += fld(1, fld(1, reference(uuid_reference(row))) + fld(2, reference(cell)))
        cells_entry = add(fld(6, cells))
        columns += fld(1, fld(1, reference(uuid_reference(len(row_uuids) + column))) + fld(2, reference(cells_entry)))
    cell_columns = add(fld(6, columns))
    entries[0] = fld(13, fint(1, 0)
                     + fld(3, fint(1, 0) + fld(2, reference(rows_entry)))
                     + fld(3, fint(1, 1) + fld(2, reference(columns_entry)))
                     + fld(3, fint(1, 2) + fld(2, reference(cell_columns))))
    data = (b"".join(fld(3, entry) for entry in entries)
            + b"".join(fstr(4, key) for key in keys)
            + b"".join(fstr(5, kind) for kind in types)
            + b"".join(fld(6, item) for item in uuids))
    return gzip.compress(fld(2, fint(2, 0) + fld(3, data)))


TITLE, HEADING, SUBHEADING, MONO, BULLET, NUMBERED, CHECK = 0, 1, 2, 4, 100, 102, 103
OBJECT = "￼"

COLUMNS = [
    "Z_PK INTEGER PRIMARY KEY", "Z_ENT INTEGER", "Z_OPT INTEGER", "ZIDENTIFIER TEXT",
    # Note
    "ZTITLE1 TEXT", "ZSNIPPET TEXT", "ZFOLDER INTEGER", "ZACCOUNT7 INTEGER", "ZCREATIONDATE3 REAL",
    "ZMODIFICATIONDATE1 REAL", "ZISPINNED INTEGER", "ZISPASSWORDPROTECTED INTEGER", "ZMARKEDFORDELETION INTEGER",
    "ZNOTEDATA INTEGER", "ZHASCHECKLIST INTEGER", "ZHASCHECKLISTINPROGRESS INTEGER", "ZSERVERSHAREDATA BLOB",
    # Decoys that other Notes versions use for these attributes; empty for notes here.
    "ZTITLE TEXT", "ZCREATIONDATE1 REAL", "ZACCOUNT2 INTEGER",
    # Folder and account
    "ZTITLE2 TEXT", "ZPARENT INTEGER", "ZFOLDERTYPE INTEGER", "ZOWNER INTEGER", "ZSMARTFOLDERQUERYJSON TEXT", "ZNAME TEXT",
    # Attachments and media
    "ZNOTE INTEGER", "ZTYPEUTI TEXT", "ZURLSTRING TEXT", "ZMEDIA INTEGER", "ZMERGEABLEDATA1 BLOB",
    "ZFALLBACKIMAGEGENERATION TEXT", "ZNOTE1 INTEGER", "ZTYPEUTI1 TEXT", "ZALTTEXT TEXT",
    "ZFILENAME TEXT", "ZGENERATION1 TEXT", "ZACCOUNT6 INTEGER",
]


def build(home):
    container = Path(home) / "Library" / "Group Containers" / "group.com.apple.notes"
    container.mkdir(parents=True, exist_ok=True)
    database_path = container / "NoteStore.sqlite"
    for suffix in ("", "-wal", "-shm"):
        Path(str(database_path) + suffix).unlink(missing_ok=True)

    database = sqlite3.connect(database_path)
    database.execute("CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER)")
    database.execute("CREATE TABLE Z_METADATA (Z_VERSION INTEGER PRIMARY KEY, Z_UUID VARCHAR(255), Z_PLIST BLOB)")
    database.execute(f"CREATE TABLE ZICCLOUDSYNCINGOBJECT ({', '.join(COLUMNS)})")
    database.execute("CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZNOTE INTEGER, ZDATA BLOB)")
    for entity, name in [(5, "ICAttachment"), (8, "ICHashtag"), (9, "ICInlineAttachment"), (11, "ICMedia"),
                         (12, "ICNote"), (14, "ICAccount"), (15, "ICFolder"), (19, "ICNoteData")]:
        database.execute("INSERT INTO Z_PRIMARYKEY VALUES (?, ?, 0, 0)", (entity, name))
    database.execute("INSERT INTO Z_METADATA VALUES (1, 'FIXTURE-STORE', NULL)")

    def insert(**values):
        names = ", ".join(values)
        database.execute(f"INSERT INTO ZICCLOUDSYNCINGOBJECT ({names}) VALUES ({', '.join('?' for _ in values)})",
                         list(values.values()))

    account = "FIXTURE-ACCOUNT"
    insert(Z_PK=1, Z_ENT=14, ZIDENTIFIER=account, ZNAME="iCloud")
    folders = {2: ("Notes", None, 0), 3: ("Work", None, 0), 4: ("Projects", 3, 0), 5: ("Recipes", None, 0),
               6: ("Recently Deleted", None, 1)}
    for pk, (name, parent, kind) in folders.items():
        insert(Z_PK=pk, Z_ENT=15, ZIDENTIFIER=f"FOLDER-{pk}", ZTITLE2=name, ZPARENT=parent, ZFOLDERTYPE=kind,
               ZOWNER=1, ZMARKEDFORDELETION=0)

    now = time.time() - CORE_DATA_EPOCH
    hour = 3600
    next_pk = [100]

    def new_pk():
        next_pk[0] += 1
        return next_pk[0]

    def add_note(pk, title, folder, runs, age_hours, pinned=0, checklist=0, open_checklist=0, locked=0, snippet=""):
        data_pk = 1000 + pk
        if not locked:
            database.execute("INSERT INTO ZICNOTEDATA VALUES (?, 19, ?, ?)", (data_pk, pk, note_data(runs)))
        insert(Z_PK=pk, Z_ENT=12, ZIDENTIFIER=f"NOTE-{pk}", ZTITLE1=title, ZSNIPPET=snippet, ZFOLDER=folder,
               ZACCOUNT7=1, ZCREATIONDATE3=now - age_hours * hour - 86400 * 30, ZMODIFICATIONDATE1=now - age_hours * hour,
               ZISPINNED=pinned, ZISPASSWORDPROTECTED=locked, ZMARKEDFORDELETION=0, ZNOTEDATA=None if locked else data_pk,
               ZHASCHECKLIST=checklist, ZHASCHECKLISTINPROGRESS=open_checklist)

    def add_hashtag(note, identifier, tag):
        insert(Z_PK=new_pk(), Z_ENT=9, ZIDENTIFIER=identifier, ZNOTE1=note, ZTYPEUTI1="com.apple.notes.inlinetextattachment.hashtag",
               ZALTTEXT=tag, ZMARKEDFORDELETION=0)

    add_note(10, "Weekend Groceries", 2, [
        ("Weekend Groceries\n", {"style": TITLE}),
        ("Milk\n", {"style": CHECK, "checked": True}),
        ("Sourdough bread\n", {"style": CHECK, "checked": False}),
        ("Coffee beans (", {"style": CHECK, "checked": False}),
        ("decaf", {"style": CHECK, "checked": False, "weight": 1}),
        (")\n", {"style": CHECK, "checked": False}),
        ("Remember the reusable bags. ", {}),
        (OBJECT, {"attachment": ("TAG-GROCERIES", "com.apple.notes.inlinetextattachment.hashtag")}),
    ], age_hours=1, pinned=1, checklist=1, open_checklist=1, snippet="Milk Sourdough bread Coffee beans")
    add_hashtag(10, "TAG-GROCERIES", "#groceries")

    add_note(11, "Project Roadmap", 4, [
        ("Project Roadmap\n", {"style": TITLE}),
        ("Q4 Goals\n", {"style": HEADING}),
        ("Ship the launcher plugin\n", {"style": BULLET}),
        ("Write the documentation\n", {"style": BULLET}),
        ("Collect beta feedback\n", {"style": BULLET, "indent": 1}),
        ("Milestones\n", {"style": SUBHEADING}),
        (OBJECT, {"attachment": ("TABLE-1", "com.apple.notes.table")}),
        ("\n", {}),
        ("Kickoff\n", {"style": NUMBERED}),
        ("Review\n", {"style": NUMBERED}),
        ("Details in the ", {}),
        ("design document", {"link": "https://example.com/design"}),
        (". ", {}),
        (OBJECT, {"attachment": ("TAG-WORK", "com.apple.notes.inlinetextattachment.hashtag")}),
    ], age_hours=5, snippet="Q4 Goals Ship the launcher plugin")
    add_hashtag(11, "TAG-WORK", "#work")
    insert(Z_PK=new_pk(), Z_ENT=5, ZIDENTIFIER="TABLE-1", ZNOTE=11, ZTYPEUTI="com.apple.notes.table", ZMARKEDFORDELETION=0,
           ZMERGEABLEDATA1=table_data([["Milestone", "Owner", "Due"], ["Beta", "Sam", "Nov 3"], ["Release", "Alex", "Dec 1"]]))

    image_pk = new_pk()
    media_pk = new_pk()
    add_note(12, "Pasta Carbonara", 5, [
        ("Pasta Carbonara\n", {"style": TITLE}),
        ("Serves two. Use guanciale if you can find it.\n", {}),
        (OBJECT, {"attachment": ("IMAGE-1", "public.png")}),
        ("\n", {}),
        ("Ingredients\n", {"style": SUBHEADING}),
        ("200 g spaghetti\n", {"style": BULLET}),
        ("2 egg yolks and 1 whole egg\n", {"style": BULLET}),
        ("50 g pecorino\n", {"style": BULLET}),
    ], age_hours=30, snippet="Serves two. Use guanciale if you can find it.")
    insert(Z_PK=image_pk, Z_ENT=5, ZIDENTIFIER="IMAGE-1", ZNOTE=12, ZTYPEUTI="public.png", ZTITLE="carbonara.png",
           ZMEDIA=media_pk, ZMARKEDFORDELETION=0)
    insert(Z_PK=media_pk, Z_ENT=11, ZIDENTIFIER="MEDIA-1", ZFILENAME="carbonara.png", ZGENERATION1="1_GEN", ZACCOUNT6=1)
    media_folder = container / "Accounts" / account / "Media" / "MEDIA-1" / "1_GEN"
    media_folder.mkdir(parents=True, exist_ok=True)
    icon = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ClippingPicture.icns"
    subprocess.run(["sips", "-s", "format", "png", "-z", "180", "180", icon, "--out", str(media_folder / "carbonara.png")],
                   check=True, capture_output=True)

    add_note(13, "Design Review – Meeting Notes", 3, [
        ("Design Review – Meeting Notes\n", {"style": TITLE}),
        ("Decisions: keep the sidebar, move export into the toolbar.\n", {}),
        ("let query = \"#work in:projects\"\n", {"style": MONO}),
        ("Follow up with the team on Friday.", {}),
    ], age_hours=50, snippet="Decisions: keep the sidebar")

    add_note(14, "Ideas", 2, [
        ("Ideas\n", {"style": TITLE}),
        ("A launcher command for every Notes folder\n", {"style": BULLET}),
        ("Markdown export templates\n", {"style": BULLET}),
        (OBJECT, {"attachment": ("TAG-IDEAS", "com.apple.notes.inlinetextattachment.hashtag")}),
    ], age_hours=120, snippet="A launcher command for every Notes folder")
    add_hashtag(14, "TAG-IDEAS", "#ideas")

    add_note(15, "Travel Packing List", 2, [
        ("Travel Packing List\n", {"style": TITLE}),
        ("Passport\n", {"style": CHECK, "checked": True}),
        ("Chargers\n", {"style": CHECK, "checked": True}),
        ("Booking: ", {}),
        (OBJECT, {"attachment": ("URL-1", "public.url")}),
    ], age_hours=400, checklist=1, snippet="Passport Chargers")
    insert(Z_PK=new_pk(), Z_ENT=5, ZIDENTIFIER="URL-1", ZNOTE=15, ZTYPEUTI="public.url", ZTITLE="Hotel reservation",
           ZURLSTRING="https://example.com/booking", ZMARKEDFORDELETION=0)

    add_note(16, "Locked Diary", 2, [], age_hours=200, locked=1)
    add_note(17, "Old Draft", 6, [("Old Draft\n", {"style": TITLE}), ("Nothing to keep.", {})], age_hours=600)

    database.commit()
    database.close()
    return database_path


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    print(build(sys.argv[1]))
