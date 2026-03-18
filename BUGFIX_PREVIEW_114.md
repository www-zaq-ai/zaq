# Bug Fix: File Preview Broken in Playground (PR #114)

## Issue Summary
File preview from playground sources was broken - clicking on referenced sources resulted in "File not found" error.

## Root Cause

The bug occurred because of a mismatch between how files are ingested and how they are accessed for preview:

1. **Volume-aware ingestion**: When files are ingested from volumes (configured in `config :zaq, Zaq.Ingestion, volumes: %{...}`), the source path is stored as a relative path without the volume prefix (e.g., `test/test.md`)

2. **Non-volume-aware preview**: The preview system (`FilePreviewLive`, `FileController`) only resolved paths against the base path, not against configured volumes

3. **Path mismatch**: When a user clicked on a source in the playground, the system tried to resolve `test/test.md` against the base path only, ignoring all configured volumes

## Files Modified

### 1. `lib/zaq/ingestion/ingestion.ex`
**Changes:**
- Updated `can_access_file?/2` to handle volume-prefixed paths by checking for documents both with and without the volume prefix
- Made `normalize_source/1` public to support path normalization across modules

**Key addition:**
```elixir
def can_access_file?(relative_path, current_user) do
  source = normalize_source(relative_path)

  # Try to find document by source, handling both legacy and volume-aware paths
  doc =
    case Document.get_by_source(source) do
      nil ->
        # If not found and path has volume prefix, try without it
        case String.split(source, "/", parts: 2) do
          [_volume, rest] -> Document.get_by_source(rest)
          _ -> nil
        end
      found -> found
    end
  # ... rest of access control logic
end
```

### 2. `lib/zaq_web/live/bo/ai/file_preview_live.ex`
**Changes:**
- Added `resolve_path_with_fallback/1` helper that first tries standard resolution, then falls back to searching in all configured volumes
- Added `try_find_in_volumes/1` helper that attempts to resolve paths in each configured volume

**Key addition:**
```elixir
defp resolve_path_with_fallback(relative_path) do
  case FileExplorer.resolve_path(relative_path) do
    {:ok, full_path} -> {:ok, full_path}
    {:error, :enoent} -> try_find_in_volumes(relative_path)
    error -> error
  end
end

defp try_find_in_volumes(relative_path) do
  volumes = FileExplorer.list_volumes()
  Enum.reduce_while(Map.keys(volumes), {:error, :enoent}, fn volume_name, acc ->
    case FileExplorer.resolve_path(volume_name, relative_path) do
      {:ok, full_path} -> {:halt, {:ok, full_path}}
      _ -> {:cont, acc}
    end
  end)
end
```

### 3. `lib/zaq_web/controllers/file_controller.ex`
**Changes:**
- Added same volume-aware fallback resolution as `FilePreviewLive`
- Updated `show/2` function to use `resolve_path_with_fallback/1`

## Tests Added

### 1. `test/zaq/ingestion/ingestion_test.exs`
Added comprehensive tests for `can_access_file?/2`:
- Access to files with no Document record
- Denial of access for files owned by different role
- Access when file is shared with user's role
- Access for super_admin
- Volume-prefixed paths handling
- Public role sharing

### 2. `test/zaq_web/controllers/file_controller_test.exs`
Added tests:
- Serves files from configured volumes
- Access denied when user cannot access file

### 3. `test/zaq_web/live/bo/ai/file_preview_live_test.exs`
Added tests:
- Finds files in configured volumes
- Finds files in subdirectories within volumes
- Respects access control for files in volumes

## How to Verify

1. **Configure volumes** in your config:
```elixir
config :zaq, Zaq.Ingestion,
  volumes: %{
    "default" => "/path/to/documents",
    "docs" => "/path/to/docs"
  }
```

2. **Ingest a file** from a volume via the ingestion UI or API

3. **Ask a question** in the playground that references that file

4. **Click on the source** - the file preview should now load successfully instead of showing "File not found"

## Related Issues
- Issue mentions PR #114 was tested but the issue was not resolved
- Issue also mentions preview is not working from within the ingestion UI (same root cause)

## Breaking Changes
None - this fix is backward compatible. Files in the base path continue to work, and volume-aware paths now also work.
