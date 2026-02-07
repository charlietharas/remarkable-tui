#!/usr/bin/env bash
# reMarkable pdf export TUI:
# browse filesystem and instantly export and open documents in chrome
# depends on RCU (https://www.davisr.me/projects/rcu/)

set -eo pipefail

SSH_HOST="remarkable-usb" # see README
OPEN_CMD="$(command -v google-chrome-stable) %s &>/dev/null &" # open after export (%s=abs filepath)
RCU_EXPORT_FORMAT="--export-pdf-rm" # see rcu --help
EXPORT_DIR_1="/tmp" # i use (enter) for one-time viewing
EXPORT_DIR_2="$HOME/downloads" # i use these for actually exporting
EXPORT_KEY_2="ctrl-d" 
CACHE_DIR="/tmp/rm-export-meta" # document metadata is cached here (script will need it)
CACHE_TTL=1200 # seconds

mkdir -p "$CACHE_DIR"

trap 'exit 0' INT TERM

cache_fresh() {
    local cache_file="$1"
    [[ -f "$cache_file" ]] && [[ $(($(date +%s) - $(stat -c %Y "$cache_file"))) -lt $CACHE_TTL ]]
}

refresh_cache() {
    printf "Loading data from reMarkable...\n" >&2

    local collections_file="$CACHE_DIR/collections.txt"
    local collections_full_file="$CACHE_DIR/collections_full.txt"
    local documents_file="$CACHE_DIR/documents.txt"

    # fetch collections with parent info
    ssh "$SSH_HOST" '
        cd /home/root/.local/share/remarkable/xochitl/
        count=0
        total=$(ls *.metadata 2>/dev/null | wc -l)
        for f in *.metadata; do
            count=$((count + 1))
            if [ $((count % 30)) -eq 0 ]; then
                printf "\rLoading collections... %d/%d" "$count" "$total" >&2
            fi
            if grep -q "\"type\".*CollectionType" "$f" 2>/dev/null; then
                id="${f%.metadata}"
                name=$(grep "\"visibleName\":" "$f" | sed "s/.*\"visibleName\": *\"\([^\"]*\)\".*/\1/")
                parent=$(grep "\"parent\":" "$f" | sed "s/.*\"parent\": *\"\([^\"]*\)\".*/\1/")
                # skip deleted
                if [[ "$parent" != "trash" ]] && ! grep -q "\"deleted\" *true" "$f" 2>/dev/null; then
                    echo "$id	$name	$parent"
                fi
            fi
        done
        printf "\rLoading collections... Done! %d items\n" "$total" >&2
    ' > "$collections_file"

    # build collections with parent info for path building
    cp "$collections_file" "$collections_full_file"

    # fetch all documents with their parent collection
    ssh "$SSH_HOST" '
        cd /home/root/.local/share/remarkable/xochitl/
        count=0
        total=$(ls *.metadata 2>/dev/null | wc -l)
        for f in *.metadata; do
            count=$((count + 1))
            if [ $((count % 30)) -eq 0 ]; then
                printf "\rLoading documents... %d/%d" "$count" "$total" >&2
            fi
            if grep -q "\"type\".*DocumentType" "$f" 2>/dev/null; then
                # skip deleted
                if ! grep -q "\"deleted\" *true" "$f" 2>/dev/null; then
                    id="${f%.metadata}"
                    name=$(grep "\"visibleName\":" "$f" | sed "s/.*\"visibleName\": *\"\([^\"]*\)\".*/\1/")
                    parent=$(grep "\"parent\":" "$f" | sed "s/.*\"parent\": *\"\([^\"]*\)\".*/\1/")
                    echo "$id	$name	$parent"
                fi
            fi
        done
        printf "\rLoading documents... Done! %d items\n" "$total" >&2
    ' > "$documents_file"

    # build full paths for all collections
    local paths_file="$CACHE_DIR/collections_paths.txt"

    awk -F'\t' '
    BEGIN {
        # load all collections into memory
        while ((getline < "'"$collections_full_file"'") > 0) {
            id = $1
            name = $2
            parent = $3
            collections[id] = name
            parents[id] = parent
            ids[++count] = id
        }
    }
    END {
        # build paths for each collection
        for (i = 1; i <= count; i++) {
            id = ids[i]
            path_parts[0] = collections[id]

            # walk up parents
            current_id = parents[id]
            depth = 0
            max_depth = 10

            while (current_id in collections && depth < max_depth) {
                path_parts[++depth] = collections[current_id]
                current_id = parents[current_id]
            }

            # build path in reverse order
            full_path = ""
            for (j = depth; j >= 0; j--) {
                if (full_path != "") full_path = full_path "/"
                full_path = full_path path_parts[j]
            }

            print id "\t" full_path
        }
    }
    ' "$collections_full_file" > "$paths_file"

    touch "$CACHE_DIR/.last_update"
}

get_collections_with_paths() {
    cat "$CACHE_DIR/collections_paths.txt" | sort -f -k2
}

get_subcollections() {
    local parent_id="$1"
    awk -F'\t' -v pid="$parent_id" '$3 == pid {print $1 "\t" $2}' "$CACHE_DIR/collections_full.txt" | sort -f -k2
}

get_collection_parent() {
    local collection_id="$1"
    awk -F'\t' -v cid="$collection_id" '$1 == cid {print $3; exit}' "$CACHE_DIR/collections_full.txt"
}

get_all_documents() {
    cut -f1,2 "$CACHE_DIR/documents.txt"
}

get_documents_in_collection() {
    local collection_id="$1"
    awk -F'\t' -v cid="$collection_id" '$3 == cid {print $1 "\t" $2}' "$CACHE_DIR/documents.txt"
}

get_collection_name() {
    local collection_id="$1"
    if [[ "$collection_id" == "ALL" ]]; then
        echo "All Documents"
    else
        # try to get the full path from paths file first
        local full_path
        full_path=$(awk -F'\t' -v cid="$collection_id" '$1 == cid {print $2; exit}' "$CACHE_DIR/collections_paths.txt" 2>/dev/null)
        if [[ -n "$full_path" ]]; then
            echo "$full_path"
        else
            # fall back to just the name
            awk -F'\t' -v cid="$collection_id" '$1 == cid {print $2; exit}' "$CACHE_DIR/collections_full.txt"
        fi
    fi
}

export_document() {
    local doc_id="$1"
    local name="$2"
    local key_pressed="$3"

    local safe_name
    safe_name=$(echo "$name" | tr -cd '[:alnum:].,_ -' | tr ' ' '_' | sed 's/^\.*//')

    local export_dir
    if [[ "$key_pressed" == "$EXPORT_KEY_2" ]]; then
        export_dir="$EXPORT_DIR_2"
    else
        export_dir="$EXPORT_DIR_1"
    fi

    local pdf_path="$export_dir/${safe_name}.pdf"

    echo "Exporting '$name'..." >&2
    # change the grep args to filter out noise from RCU output
    rcu --cli --no-check-compat --autoconnect "$RCU_EXPORT_FORMAT" "$doc_id" "$pdf_path" 2>&1 | grep -vE "could not get|Some data|template broken|cat: can't open|set_color_by_index|==.*==>|^saving$" || true
    echo "Done! Exported to: $pdf_path" >&2
    # output path to open it later
    echo "$pdf_path"
}

open_in_browser() {
    local pdf_path="$1"
    if [[ -n "$OPEN_CMD" ]]; then
        eval "$(printf "$OPEN_CMD" "$pdf_path")"
    fi
}

navigate_to_parent() {
    local current_id="$1"
    local parent_id
    parent_id=$(get_collection_parent "$current_id")

    if [[ -z "$parent_id" || "$parent_id" == "" ]]; then
        # main menu
        echo ""
    else
        echo "$parent_id"
    fi
}

main() {
    FORCE_REFRESH=false

    for arg in "$@"; do
        case "$arg" in
            --help|-h)
                echo "usage: rm-export.sh [--refresh_cache|-r] [--help|-h]"
                exit 0
                ;;
            --refresh_cache|-r)
                FORCE_REFRESH=true
                ;;
        esac
    done

    if $FORCE_REFRESH || ! cache_fresh "$CACHE_DIR/.last_update"; then
        refresh_cache
    fi

    # current collection state
    local current_collection_id=""
    local current_collection_name=""

    while true; do
        # if no current collection, show picker
        if [[ -z "$current_collection_id" ]]; then
            local collection_line
            collection_line=$(printf "ALL\tAll Documents\n" | cat - <(get_collections_with_paths) | \
                fzf --prompt="Collection: " --delimiter='\t' --with-nth=2 \
                    --header='Enter: Browse | Esc/Ctrl-C: Quit' --tabstop=1) || exit 0

            current_collection_id=$(echo "$collection_line" | cut -f1)
            current_collection_name=$(echo "$collection_line" | cut -f2)
        fi

        # build list: documents + subcollections in this collection
        local items=()
        local header="[Esc: Back | Tab: Select | Enter: Export $EXPORT_DIR_1 | Ctrl-D: Export $EXPORT_DIR_2]"

        # ".." to go to parent
        if [[ "$current_collection_id" != "ALL" ]]; then
            local parent_id
            parent_id=$(get_collection_parent "$current_collection_id")
            if [[ -n "$parent_id" && "$parent_id" != "" ]]; then
                local parent_name
                parent_name=$(get_collection_name "$parent_id")
                parent_name=$(echo "$parent_name" | awk -F'/' '{print $NF}')
                items+=("PARENT:$parent_id	..	($parent_name)")
            else
                items+=("MAIN	..	(main menu)")
            fi
        fi

        # add subcollections if not "ALL"
        if [[ "$current_collection_id" != "ALL" ]]; then
            local subcols
            subcols=$(get_subcollections "$current_collection_id")
            if [[ -n "$subcols" ]]; then
                # add subcollections with a folder indicator
                while IFS=$'\t' read -r id name; do
                    items+=("COLL:$id	📁 $name")
                done <<< "$subcols"
            fi
        fi

        # add documents
        local docs
        if [[ "$current_collection_id" == "ALL" ]]; then
            docs=$(get_all_documents)
        else
            docs=$(get_documents_in_collection "$current_collection_id")
        fi

        # combine and show in fzf
        local combined=""
        for item in "${items[@]}"; do
            combined+="$item"$'\n'
        done
        combined+="$docs"

        local selected
        selected=$(echo -n "$combined" | fzf --prompt="[$current_collection_name] " --delimiter='\t' --with-nth=2 \
            --header="$header" --tabstop=1 --expect="$EXPORT_KEY_2" --multi) || { current_collection_id=""; current_collection_name=""; continue; }

        # check secondary export key
        local key_pressed=""
        if [[ "$(echo "$selected" | head -n 1)" == "$EXPORT_KEY_2" ]]; then
            key_pressed="$EXPORT_KEY_2"
            selected=$(echo "$selected" | tail -n +2)
        fi

        [[ -z "$selected" ]] && continue

        # check for navigation items
        while IFS=$'\t' read -r item_id _; do
            [[ -z "$item_id" ]] && continue

            if [[ "${item_id:0:5}" == "COLL:" ]]; then
                # navigate into subcollection
                current_collection_id="${item_id:5}"
                current_collection_name=$(get_collection_name "$current_collection_id")
                continue 2
            fi

            if [[ "$item_id" == "MAIN" ]]; then
                # go to main menu
                current_collection_id=""
                current_collection_name=""
                continue 2
            fi

            if [[ "${item_id:0:7}" == "PARENT:" ]]; then
                # go to parent
                current_collection_id="${item_id:7}"
                current_collection_name=$(get_collection_name "$current_collection_id")
                continue 2
            fi
        done <<< "$selected"

        # export documents
        local pdf_paths=()
        while IFS=$'\t' read -r doc_id name; do
            [[ -z "$doc_id" ]] && continue
            local pdf_path
            pdf_path=$(export_document "$doc_id" "$name" "$key_pressed")
            pdf_paths+=("$pdf_path")
        done <<< "$selected"

        for pdf_path in "${pdf_paths[@]}"; do
            open_in_browser "$pdf_path"
        done
    done
}

main "$@"
