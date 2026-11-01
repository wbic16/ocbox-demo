# showcase sample project

Source files for `demo/showcase.sh`. The script copies this directory into
its own state area (`demo/.showcase-state/project`), writes an
`.ocbox.json` there pointing the phext store at
`demo/.showcase-state/store`, and runs one ocbox session that drives real
tools — ffmpeg, jq, sqlite3, git, rg, tar/gzip/zip, gcc, node, openssl,
curl — against these files.
