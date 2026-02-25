---
name: Disk Image Testing
description: Instructions and scripts for creating, mounting, and manipulating raw disk images to test the Vivacity file recovery engines.
---

# Disk Image Testing Skill

When working on Vivacity's raw disk carving capabilities (Deep Scan, FAT/NTFS/APFS Parsing), it is essential to have a reproducible and safe way to test changes without requiring physical hardware (like SD cards or USB drives).

This skill provides instructions for generating raw disk images (`.dmg` or `.img`), formatting them with specific filesystems, adding files to them, and simulating deletions so the scanner can be tested.

## Why use this skill?
- M6 (Scan Engine Hardening) and M8 (Deep Scan FS-Aware Carving) require reading raw sectors and parsing FAT tables or NTFS MFTs.
- Real hardware is slow, unpredictable, and requires manual intervention to plug/unplug.
- Small (e.g., 50MB) disk images are fast to scan and perfectly controllable.

## How to Create and Use a Test Image

### 1. Create a blank disk image
Use `hdiutil` to create a new disk image of a specific size and format.

```bash
# Create a 50MB FAT32 disk image
hdiutil create -size 50m -fs "MS-DOS FAT32" -volname "TEST_FAT32" ~/Desktop/test_fat32.dmg

# Create a 50MB ExFAT disk image
hdiutil create -size 50m -fs "ExFAT" -volname "TEST_EXFAT" ~/Desktop/test_exfat.dmg

# Create a 100MB APFS disk image
hdiutil create -size 100m -fs "APFS" -volname "TEST_APFS" ~/Desktop/test_apfs.dmg
```

### 2. Mount and Add Files
Mac will automatically mount created images. If it's already created but unmounted, attach it:
```bash
hdiutil attach ~/Desktop/test_fat32.dmg
```

Copy test images and videos from a designated test folder to the volume:
```bash
cp ~/Desktop/test_photo.jpg /Volumes/TEST_FAT32/
cp ~/Desktop/test_video.mp4 /Volumes/TEST_FAT32/
```

### 3. Simulate File Deletion
To properly test Vivacity, files must be "deleted" just as a user would. On macOS, sending a file to the Trash places it in `.Trashes`. To simulate a hard deletion (like formatting or bypassing the trash, which sets `0xE5` in FAT), you can use `rm`:
```bash
rm /Volumes/TEST_FAT32/test_photo.jpg
```

### 4. Unmount for Raw Scanning
Vivacity's `PrivilegedDiskReader` works best when the volume is completely unmounted, allowing raw `/dev/diskX` access without OS interference.
```bash
# 1. Find the disk identifier (e.g. /dev/disk4)
diskutil list

# 2. Unmount the volume (but keep the disk attached)
diskutil unmountDisk /dev/disk4
```

### 5. Running Vivacity Tests
You can now run Vivacity and point it to the `/dev/diskX` device corresponding to the attached `.dmg` file. The core engine should be able to scan its sectors, detect deleted files, and recover them.

When finished, detach the disk image entirely:
```bash
hdiutil detach /dev/disk4
```
