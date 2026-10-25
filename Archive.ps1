function Get-AutoCompactFormatAvailability([string]$Format) {
    $name = ([string]$Format).ToUpperInvariant()
    if ($name -in @('ZIP','TAR.GZ')) {
        return [pscustomobject]@{ Available = $true; Reason = 'Built into Windows PowerShell / .NET; no external installation required.' }
    }
    return [pscustomobject]@{ Available = $false; Reason = ('Unsupported archive format: {0}. Choose ZIP or TAR.GZ.' -f $Format) }
}

function Initialize-AutoCompactTarWriter {
    if ('CodexAutoCompact.Archives.PaxTarWriter' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Globalization;

namespace CodexAutoCompact.Archives {
    // POSIX pax headers carry UTF-8 paths and large-file sizes. Content is streamed
    // directly to the caller's GZipStream, with no staging copy on disk.
    public sealed class PaxTarWriter {
        readonly Stream output;
        long sequence;
        static readonly Encoding Utf8 = new UTF8Encoding(false);
        static readonly byte[] ZeroBlock = new byte[512];
        public PaxTarWriter(Stream output) { this.output = output; }

        static void Text(byte[] header, int start, int count, string value) {
            byte[] bytes = Encoding.ASCII.GetBytes(value);
            if (bytes.Length > count) throw new InvalidDataException("Tar header field is too long.");
            Buffer.BlockCopy(bytes, 0, header, start, bytes.Length);
        }
        static string Octal(long value, int digits) {
            string result = Convert.ToString(Math.Max(0, value), 8);
            if (result.Length > digits) throw new InvalidDataException("Tar header number is too large.");
            return result.PadLeft(digits, '0');
        }
        static byte[] Header(string name, long length, long seconds, char type) {
            byte[] header = new byte[512];
            Text(header, 0, 100, name);
            Text(header, 100, 8, "0000644\0");
            Text(header, 108, 8, "0000000\0");
            Text(header, 116, 8, "0000000\0");
            Text(header, 124, 12, Octal(length, 11) + "\0");
            Text(header, 136, 12, Octal(seconds, 11) + "\0");
            for (int i = 148; i < 156; i++) header[i] = 32;
            header[156] = (byte)type;
            Text(header, 257, 6, "ustar\0");
            Text(header, 263, 2, "00");
            long sum = 0;
            foreach (byte value in header) sum += value;
            Text(header, 148, 8, Octal(sum, 6) + "\0 ");
            return header;
        }
        static string PaxLine(string key, string value) {
            string content = key + "=" + value + "\n";
            int baseLength = Utf8.GetByteCount(content) + 1;
            int length = baseLength + 1;
            while (true) {
                int next = baseLength + length.ToString(CultureInfo.InvariantCulture).Length;
                if (next == length) break;
                length = next;
            }
            return length.ToString(CultureInfo.InvariantCulture) + " " + content;
        }
        void Pad(long length) {
            int padding = (int)((512 - (length % 512)) % 512);
            if (padding != 0) output.Write(ZeroBlock, 0, padding);
        }
        public void AddFile(string path, string archivePath, long expectedLength, long expectedTicks) {
            if (archivePath.StartsWith("/", StringComparison.Ordinal) || archivePath.IndexOf('\\') >= 0)
                throw new InvalidDataException("Archive paths must be relative and use forward slashes.");
            foreach (string part in archivePath.Split('/'))
                if (part == ".." || part == "." || part.Length == 0)
                    throw new InvalidDataException("Unsafe archive entry path.");

            using (FileStream input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                FileInfo info = new FileInfo(path);
                if (input.Length != expectedLength || info.LastWriteTimeUtc.Ticks != expectedTicks)
                    throw new IOException("Source changed before archive read: " + path);
                long seconds = (new DateTime(expectedTicks, DateTimeKind.Utc).Ticks - 621355968000000000L) / 10000000L;
                string stamp = ((decimal)(expectedTicks - 621355968000000000L) / 10000000M).ToString("0.#######", CultureInfo.InvariantCulture);
                byte[] pax = Utf8.GetBytes(PaxLine("path", archivePath) + PaxLine("size", expectedLength.ToString(CultureInfo.InvariantCulture)) + PaxLine("mtime", stamp));
                string label = (++sequence).ToString("D8", CultureInfo.InvariantCulture);
                byte[] paxHeader = Header("PaxHeaders/" + label, pax.LongLength, Math.Max(0, seconds), 'x');
                output.Write(paxHeader, 0, paxHeader.Length);
                output.Write(pax, 0, pax.Length);
                Pad(pax.LongLength);
                // pax size overrides this legacy header field for files >= 8 GiB.
                byte[] fileHeader = Header("data/" + label, expectedLength < 8589934592L ? expectedLength : 0L, Math.Max(0, seconds), '0');
                output.Write(fileHeader, 0, fileHeader.Length);
                byte[] buffer = new byte[81920];
                long copied = 0;
                int count;
                while ((count = input.Read(buffer, 0, buffer.Length)) != 0) {
                    output.Write(buffer, 0, count);
                    copied += count;
                }
                if (copied != expectedLength) throw new IOException("Source changed during archive read: " + path);
                Pad(copied);
            }
        }
        public void Finish() {
            output.Write(ZeroBlock, 0, ZeroBlock.Length);
            output.Write(ZeroBlock, 0, ZeroBlock.Length);
        }
    }
}
'@
}

function Assert-AutoCompactArchiveDirectory([string]$Directory) {
    if ($Directory -notmatch '^[A-Za-z]:[\\/]') { throw 'Use an absolute local archive directory.' }
    $cursor = [IO.Path]::GetFullPath($Directory)
    while ($cursor) {
        if ([IO.Directory]::Exists($cursor) -or [IO.File]::Exists($cursor)) {
            if (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Archive directory has a reparse point.'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function New-AutoCompactArchive($Records, [string]$Directory, [string]$Format = 'ZIP', [string]$Compression = 'Optimal') {
    $availability = Get-AutoCompactFormatAvailability $Format
    if (-not $availability.Available) { throw $availability.Reason }
    if ($Compression -notin @('Fastest','Optimal')) { throw 'Compression must be Fastest or Optimal.' }
    if ($null -eq (Get-Command Test-Unchanged -CommandType Function -ErrorAction SilentlyContinue)) {
        throw 'The caller must provide Test-Unchanged to verify source files before archiving.'
    }
    $Format = $Format.ToUpperInvariant()
    Assert-AutoCompactArchiveDirectory $Directory
    $Directory = [IO.Path]::GetFullPath($Directory)
    $null = [IO.Directory]::CreateDirectory($Directory)
    Assert-AutoCompactArchiveDirectory $Directory
    Add-Type -AssemblyName System.IO.Compression
    if ($Format -eq 'TAR.GZ') { Initialize-AutoCompactTarWriter }
    $requiredBytes = [decimal](1MB)
    foreach ($record in $Records) { $requiredBytes += [decimal]$record.Length + [decimal]8192 }
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Directory))
    if (-not $drive.IsReady) { throw 'The archive destination drive is not ready.' }
    if ($requiredBytes -gt [decimal]$drive.AvailableFreeSpace) {
        throw ('Not enough free space for a safe archive attempt. Need a conservative {0:N0} bytes (original size plus overhead); available {1:N0} bytes.' -f $requiredBytes, $drive.AvailableFreeSpace)
    }
    $level = [IO.Compression.CompressionLevel]::$Compression
    $extension = if ($Format -eq 'ZIP') { '.zip' } else { '.tar.gz' }
    $name = 'CodexAutoCompact-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8) + $extension
    $finalPath = Join-Path $Directory $name
    $partialPath = $finalPath + '.partial'
    $stream = $null
    $container = $null
    $files = 0
    $originalBytes = 0L
    $rootLabels = @{}
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $stream = [IO.File]::Open($partialPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        if ($Format -eq 'ZIP') {
            $container = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        } else {
            $container = [IO.Compression.GZipStream]::new($stream, $level, $true)
            $tarWriter = [CodexAutoCompact.Archives.PaxTarWriter]::new($container)
        }
        foreach ($record in $Records) {
            if (-not (Test-Unchanged $record)) { throw ('Source changed or is unavailable: ' + $record.Path) }
            $root = [IO.Path]::GetFullPath([string]$record.Root).TrimEnd('\')
            $path = [IO.Path]::GetFullPath([string]$record.Path)
            if (-not $path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Source file is outside its declared root.' }
            if (-not $rootLabels.ContainsKey($root)) { $rootLabels[$root] = 'root-{0:D3}' -f ($rootLabels.Count + 1) }
            $relative = $path.Substring($root.Length).TrimStart('\').Replace('\','/')
            $entryPath = $rootLabels[$root] + '/' + $relative
            if ($Format -eq 'TAR.GZ') {
                $tarWriter.AddFile($path, $entryPath, [long]$record.Length, [long]$record.Ticks)
            } else {
                $inputStream = $null
                $outputStream = $null
                try {
                    $inputStream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                    $info = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                    if ($inputStream.Length -ne [long]$record.Length -or $info.LastWriteTimeUtc.Ticks -ne [long]$record.Ticks) { throw ('Source changed before archive read: ' + $path) }
                    $entry = $container.CreateEntry($entryPath, $level)
                    $time = [DateTime]::new([long]$record.Ticks, [DateTimeKind]::Utc)
                    if ($time.Year -lt 1980) { $time = [DateTime]::new(1980,1,1,0,0,0,[DateTimeKind]::Utc) }
                    if ($time.Year -gt 2107) { $time = [DateTime]::new(2107,12,31,23,59,58,[DateTimeKind]::Utc) }
                    $entry.LastWriteTime = [DateTimeOffset]::new($time)
                    $outputStream = $entry.Open()
                    $inputStream.CopyTo($outputStream)
                } finally {
                    if ($null -ne $outputStream) { $outputStream.Dispose() }
                    if ($null -ne $inputStream) { $inputStream.Dispose() }
                }
            }
            $files++
            $originalBytes += [long]$record.Length
        }
        if ($Format -eq 'TAR.GZ') { $tarWriter.Finish() }
        $container.Dispose()
        $container = $null
        $stream.Dispose()
        $stream = $null
        Assert-AutoCompactArchiveDirectory $Directory
        [IO.File]::Move($partialPath, $finalPath)
        $watch.Stop()
        return [pscustomobject]@{
            Path = $finalPath
            Files = $files
            OriginalBytes = $originalBytes
            ArchiveBytes = [long]([IO.FileInfo]::new($finalPath)).Length
            Seconds = [Math]::Round($watch.Elapsed.TotalSeconds, 6)
        }
    } finally {
        try {
            if ($null -ne $container) { $container.Dispose() }
        } finally {
            try {
                if ($null -ne $stream) { $stream.Dispose() }
            } finally {
                try {
                    if ([IO.File]::Exists($partialPath)) { [IO.File]::Delete($partialPath) }
                } finally { $watch.Stop() }
            }
        }
    }
}
