# Semantic Search Setup Guide

## Overview

Semantic search allows you to search by meaning/concept (e.g., "verses about forgiveness") rather than exact word matches. The embeddings database is **translation-independent** and works with ANY Bible translation (primary or secondary).

## Step 1: Ensure Required Files Are in Xcode Project

The following files should be in your Xcode project (they're likely already added):

- `ViewTheWord/OpenAIClient.swift` - OpenAI API client
- `ViewTheWord/EmbeddingsDb.swift` - Standalone embeddings database manager
- `ViewTheWord/FileLogger.swift` - File-based logging (logs to ~/viewtheword.log)

If any are missing, add them to the Xcode project:

1. Open `ViewTheWord.xcodeproj` in Xcode
2. Right-click on the `ViewTheWord` folder in the Project Navigator
3. Select "Add Files to ViewTheWord..."
4. Navigate to and select the missing files
5. Make sure "Copy items if needed" is UNCHECKED
6. Make sure the ViewTheWord target is CHECKED
7. Click "Add"
8. Build the project (⌘B) - it should succeed

## Step 2: Get an OpenAI API Key

1. Go to https://platform.openai.com
2. Sign up or log in
3. Navigate to API Keys section
4. Create a new API key
5. Copy the key (starts with `sk-...`)

## Step 3: Configure API Key in ViewTheWord

1. Launch ViewTheWord app
2. Go to Settings (⌘,)
3. Go to the "Display" tab
4. Find the "Semantic Search (v:)" section
5. Paste your OpenAI API key
6. Close Settings

## Step 4: Generate Standalone Embeddings Database

You need to run a one-time script to generate a standalone `embeddings.db` file for all ~31,000 verses. This database works with ANY Bible translation.

### Setup API Key (Choose One Option)

**Option 1: Environment Variable**
```bash
export OPENAI_API_KEY="sk-your-key-here"
```

**Option 2: Save to File**
```bash
echo "sk-your-key-here" > ~/.openai_key
```

### Run the Embedding Generator

**Recommended Usage:**
```bash
cd /Users/sukujohn.george/github/ViewTheWord

# Generate embeddings.db from any Bible file
swift Scripts/GenerateEmbeddings.swift ViewTheWord/ENG_UKJV.bible ViewTheWord/embeddings.db
```

**Other Examples:**
```bash
# Auto-create embeddings.db in same directory as Bible file
swift Scripts/GenerateEmbeddings.swift ViewTheWord/ENG_UKJV.bible

# Using tilde for home directory
swift Scripts/GenerateEmbeddings.swift ~/Downloads/ENG_UKJV.bible ~/Downloads/embeddings.db

# Using full paths
swift Scripts/GenerateEmbeddings.swift /path/to/ENG_UKJV.bible /path/to/embeddings.db

# Get help
swift Scripts/GenerateEmbeddings.swift --help
```

### What the Script Does

- Processes all 31,102 verses in batches of 100
- Generates 1536-dimensional embeddings using OpenAI's `text-embedding-3-small` model
- Creates a **standalone `embeddings.db` file** that stores verse coordinates (book/chapter/verse numbers)
- Works with ANY Bible translation (not tied to a specific translation)
- Takes ~5-10 minutes to complete
- Costs approximately $0.03 (one-time cost)

### Sample Output

```
🔮 ViewTheWord Embedding Generator
==================================================
✅ API key loaded
✅ Found Bible: /path/to/ENG_UKJV.bible
✅ Database opened
✅ Embeddings database ready: /path/to/embeddings.db
✅ Found 31102 verses

🚀 Generating embeddings...
   Model: text-embedding-3-small
   Batch size: 100
   Estimated cost: ~$0.03

✅ Batch 1/312 - 100/31102 verses (0.3%)
✅ Batch 2/312 - 200/31102 verses (0.6%)
...
✅ Batch 312/312 - 31102/31102 verses (100.0%)

✨ Done! Generated embeddings for 31102 verses in embeddings.db
   Import this file in ViewTheWord Settings → Bible → Import Embeddings
```

## Step 5: Import Embeddings Database

After generating `embeddings.db`, import it into ViewTheWord:

1. Launch ViewTheWord app
2. Go to Settings (⌘,)
3. Go to the "Bible" tab
4. Click "Import Embeddings" button
5. Select your `embeddings.db` file
6. You'll see a success message with the verse count
7. The embeddings status will show a green checkmark

The imported file will be stored in:
```
~/Library/Containers/com.viewtheword.ViewTheWord/Data/Documents/
```

## Step 6: Use Semantic Search

Once embeddings are generated, you can search by meaning:

### Search Syntax

Type `v:` followed by your concept/question:

- `v: verses about forgiveness` - Find verses about forgiveness
- `v: God's love for humanity` - Verses about divine love
- `v: nt: salvation through faith` - Search only New Testament
- `v: john: eternal life` - Search only in the book of John

### How It Works

1. Your search query is converted to an embedding (vector)
2. The embedding is compared against all verse embeddings in `embeddings.db`
3. Results are ranked by semantic similarity (cosine similarity)
4. Top 15 most relevant verses are returned as coordinates (book/chapter/verse numbers)
5. Verses are fetched from your currently selected primary/secondary Bible translation

### Cost Per Search

- Each search costs ~$0.00002 (2/100 of a cent)
- Practically free for daily use

## Architecture

### Files Created/Modified

**New Files:**
- `ViewTheWord/OpenAIClient.swift` - OpenAI API client for embeddings
- `ViewTheWord/EmbeddingsDb.swift` - Standalone embeddings database manager
- `ViewTheWord/FileLogger.swift` - File-based logging to ~/viewtheword.log
- `Scripts/GenerateEmbeddings.swift` - Creates standalone embeddings.db
- `Scripts/MigrateEmbeddings.swift` - Migrates old format to new (one-time use)
- `SEMANTIC_SEARCH_SETUP.md` - This guide

**Modified Files:**
- `ViewTheWord/Db.swift` - Added getVerse() for coordinate-based lookups, exposed bookNumberToName
- `ViewTheWord/RxVerse.swift` - Added semantic search type
- `ViewTheWord/ContentView.swift` - Uses EmbeddingsDb for coordinate-based semantic search
- `ViewTheWord/SettingsView.swift` - Added embeddings import UI with validation

### Database Schema

**Standalone embeddings.db** (translation-independent):

```sql
CREATE TABLE embeddings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    book_number INTEGER NOT NULL,      -- Book number (1-66)
    chapter_number INTEGER NOT NULL,   -- Chapter number
    verse_number INTEGER NOT NULL,     -- Verse number
    embedding BLOB NOT NULL,           -- 1536 floats (6KB per verse)
    model TEXT NOT NULL,               -- 'text-embedding-3-small'
    created_at INTEGER NOT NULL,       -- Unix timestamp
    UNIQUE(book_number, chapter_number, verse_number)
);

CREATE INDEX idx_book_chapter_verse
ON embeddings(book_number, chapter_number, verse_number);
```

**Key Design**: Stores verse coordinates instead of verse IDs, making it work with ANY Bible translation.

### Storage Size

- Embeddings: ~31,000 verses × 6KB = ~186 MB
- Stored in a **separate embeddings.db file** that can be imported independently
- Works with any Bible translation (primary or secondary)

## Troubleshooting

### "No embeddings imported - semantic search unavailable"

- You haven't imported the embeddings database yet
- Run Step 4 to generate `embeddings.db`, then Step 5 to import it

### "Embeddings table not found" Error

- The imported file doesn't have the correct schema
- Make sure you're importing a file created by `GenerateEmbeddings.swift`
- Check the file has the `.db`, `.sqlite`, or `.bible` extension

### "OpenAI API key not set" Error

- Configure your API key in Settings → Display → Semantic Search
- See Step 3 above

### Script Fails with API Error

- Check your API key is valid
- Ensure you have credits on your OpenAI account
- Check internet connection

### No Search Results

- Try adjusting the minimum similarity in Settings → Display
- Lower values (0.2-0.3) = more results, higher values (0.4-0.5) = stricter matches
- Try a different search query or phrasing
- Check that you're using the `v:` prefix

### Import Validation Errors

The import validates:
- File must be a valid SQLite database (checks header)
- Must have an `embeddings` table
- Table must have columns: book_number, chapter_number, verse_number, embedding
- If validation fails, the file won't be imported

### Check Logs

Debug logs are written to `~/viewtheword.log`. Check this file for detailed error messages:
```bash
tail -f ~/viewtheword.log
```

## Migration from Old Format

If you previously had embeddings embedded in ENG_UKJVS.bible, use the migration script:

```bash
cd /Users/sukujohn.george/github/ViewTheWord

# Migrate from old format to new standalone format
swift Scripts/MigrateEmbeddings.swift ViewTheWord/ENG_UKJVS.bible ViewTheWord/embeddings.db
```

Then import the new `embeddings.db` file via Settings → Bible → Import Embeddings.

## Limitations

- Each query requires an API call (~100ms latency)
- Results are limited to top 15 verses
- Minimum similarity threshold is adjustable (default: 0.35)
- Embeddings are based on ENG_UKJV text, so accuracy may vary slightly with other translations

## Future Enhancements

Possible improvements:
- Cache recent query embeddings locally to reduce API calls
- Add similarity scores to search results UI
- Support for local embeddings (no API required)
- Generate embeddings in other languages

## Support

For issues or questions:

1. Check `~/viewtheword.log` for detailed logs (no Xcode required):
   ```bash
   tail -f ~/viewtheword.log
   ```

2. Or check console logs in Xcode when running from Xcode

The logs include:
- Embeddings database loading status
- Semantic search query results with similarity scores
- Import validation details
- API errors and network issues
