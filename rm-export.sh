#!/usr/bin/env bash
# reMarkable pdf export TUI:
# browse filesystem and instantly export and open documents in chrome
# depends on RCU

set -eo pipefail

SSH_HOST="remarkable-usb"
CHROME_CMD=$(command -v google-chrome || command -v google-chrome-stable)
EXPORT_DIR="/tmp"
CACHE_DIR="/tmp/rm-export"
CACHE_TTL=1200 # 20 min

mkdir -p "$CACHE_DIR"

# handle Ctrl+C gracefully
trap 'exit 0' INT TERM

cache_fresh() {
    local cache_file="$1"
    [[ -f "$cache_file" ]] && [[ $(($(date +%s) - $(stat -c %Y "$cache_file"))) -lt $CACHE_TTL ]]
}

# fetch all data and build cache index
refresh_cache() {
    printf "Loading data from reMarkable...\n" >&2

    local collections_file="$CACHE_DIR/collections.txt"
    local collections_full_file="$CACHE_DIR/collections_full.txt"
    local documents_file="$CACHE_DIR/documents.txt"

    # fetch collections with parent info (skip trash)
    ssh "$SSH_HOST" '
        cd /home/root/.local/share/remarkable/xochitl/
        count=0
        total=$(ls *.metadata 2>/dev/null | wc -l)
        for f in *.metadata; do
            count=$((count + 1))
            if [ $((count % 30)) -eq 0 ]; then
                printf "\rLoading collections... %d/%d" "$count" "$total" >&2
            fi
            # Match both "type": "CollectionType" and "type":"CollectionType"
            if grep -q "\"type\".*CollectionType" "$f" 2>/dev/null; then
                id="${f%.metadata}"
                name=$(grep "\"visibleName\":" "$f" | sed "s/.*\"visibleName\": *\"\([^\"]*\)\".*/\1/")
                parent=$(grep "\"parent\":" "$f" | sed "s/.*\"parent\": *\"\([^\"]*\)\".*/\1/")
                # Skip trash and deleted collections
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
            # Match both "type": "DocumentType" and "type":"DocumentType"
            if grep -q "\"type\".*DocumentType" "$f" 2>/dev/null; then
                # Skip deleted documents
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
        # First pass: load all collections into memory
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
        # Second pass: build paths for each collection
        for (i = 1; i <= count; i++) {
            id = ids[i]
            path_parts[0] = collections[id]

            # Walk up parents
            current_id = parents[id]
            depth = 0
            max_depth = 10

            while (current_id in collections && depth < max_depth) {
                path_parts[++depth] = collections[current_id]
                current_id = parents[current_id]
            }

            # Build path in reverse order (root first)
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
        # try to get the full path from paths file first, fall back to just the name
        local full_path
        full_path=$(awk -F'\t' -v cid="$collection_id" '$1 == cid {print $2; exit}' "$CACHE_DIR/collections_paths.txt" 2>/dev/null)
        if [[ -n "$full_path" ]]; then
            echo "$full_path"
        else
            awk -F'\t' -v cid="$collection_id" '$1 == cid {print $2; exit}' "$CACHE_DIR/collections_full.txt"
        fi
    fi
}

# navigate to parent collection
navigate_to_parent() {
    local current_id="$1"
    local parent_id
    parent_id=$(get_collection_parent "$current_id")

    if [[ -z "$parent_id" || "$parent_id" == "" ]]; then
        # At root level, go back to collection picker
        echo ""
    else
        echo "$parent_id"
    fi
}

main() {
    FORCE_REFRESH=false

    # Parse arguments
    for arg in "$@"; do
        case "$arg" in
            --refresh|-r)
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
        local header="[Enter: Export | Esc: Parent]"

        # ".." to go to parent (if not ALL)
        if [[ "$current_collection_id" != "ALL" ]]; then
            local parent_id
            parent_id=$(get_collection_parent "$current_collection_id")
            if [[ -n "$parent_id" && "$parent_id" != "" ]]; then
                # get parent collection name for display
                local parent_name
                parent_name=$(get_collection_name "$parent_id")
                # use just the base name, not full path
                parent_name=$(echo "$parent_name" | awk -F'/' '{print $NF}')
                items+=("PARENT:$parent_id	..	($parent_name)")
            else
                # at root level, ".." goes to main menu
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
            --header="$header" --tabstop=1) || { current_collection_id=""; current_collection_name=""; continue; }

        [[ -z "$selected" ]] && continue

        local first_field
        first_field=$(echo "$selected" | cut -f1)

        if [[ "$first_field" == "MAIN" ]]; then
            # go to main menu
            current_collection_id=""
            current_collection_name=""
            continue
        fi

        if [[ "${first_field:0:7}" == "PARENT:" ]]; then
            # go to parent collection
            current_collection_id="${first_field:7}"
            current_collection_name=$(get_collection_name "$current_collection_id")
            continue
        fi

        if [[ "${first_field:0:5}" == "COLL:" ]]; then
            # user selected a subcollection
            current_collection_id="${first_field:5}"
            current_collection_name=$(get_collection_name "$current_collection_id")
            continue
        fi

        # user selected a document
        local doc_id name
        doc_id=$(echo "$selected" | cut -f1)
        name=$(echo "$selected" | cut -f2)

        local safe_name
        safe_name=$(echo "$name" | tr -cd '[:alnum:].,_ -' | tr ' ' '_' | sed 's/^\.*//')
        local pdf_path="$EXPORT_DIR/${safe_name}.pdf"

        echo "Exporting '$name'..."
        rcu --cli --no-check-compat --autoconnect --export-pdf-v "$doc_id" "$pdf_path" 2>&1 | grep -vE "could not get|Some data|template broken|cat: can't open|set_color_by_index|==.*==>|^saving$" || true
        $CHROME_CMD "$pdf_path" &>/dev/null &
        echo "Done! Exported to: $pdf_path"
    done
}

main "$@"
