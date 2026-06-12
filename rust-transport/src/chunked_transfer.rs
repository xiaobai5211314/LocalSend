//! Chunked file transfer with SHA-256 checksums and resume support.
//!
//! Implements:
//! - File splitting into 64KB chunks with sequence numbers
//! - SHA-256 hash verification per chunk and for the complete file
//! - Resume transfer by skipping already-received chunks
//! - Transfer state tracking (in-progress, paused, completed)

use std::collections::HashSet;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{TransportConfig, TransportError, TransportResult};

/// Metadata for a file transfer session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransferMetadata {
    /// Unique transfer session ID
    pub transfer_id: String,
    /// Original file name
    pub file_name: String,
    /// Total file size in bytes
    pub file_size: u64,
    /// Total number of chunks
    pub total_chunks: u32,
    /// Chunk size in bytes
    pub chunk_size: usize,
    /// SHA-256 hash of the complete file
    pub full_hash: String,
}

/// A single chunk in a file transfer.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileChunk {
    /// Transfer session ID
    pub transfer_id: String,
    /// 0-based chunk index
    pub chunk_index: u32,
    /// Total number of chunks in this transfer
    pub total_chunks: u32,
    /// Size of this chunk's payload in bytes (last chunk may be smaller)
    pub payload_size: usize,
    /// Raw chunk data
    pub data: Vec<u8>,
    /// SHA-256 hash of this chunk's data
    pub checksum: String,
}

/// Resume information for an interrupted transfer.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResumeInfo {
    /// Transfer session ID
    pub transfer_id: String,
    /// Set of already-received chunk indices
    pub received_chunks: HashSet<u32>,
    /// Next expected chunk index
    pub next_expected: u32,
    /// Total chunks in the transfer
    pub total_chunks: u32,
    /// Partial output file path
    pub partial_path: String,
    /// Total file size
    pub file_size: u64,
    /// Expected full file hash
    pub full_hash: String,
}

/// State of the chunked transfer for the sender side.
pub struct ChunkedSender {
    /// File being sent
    file_path: PathBuf,
    /// Transfer metadata
    metadata: TransferMetadata,
    /// Total chunks already prepared
    prepared_chunks: Vec<FileChunk>,
    /// Next chunk index to send
    next_index: u32,
    /// Whether all chunks have been sent
    complete: bool,
}

/// State of the chunked transfer for the receiver side.
pub struct ChunkedReceiver {
    /// Transfer metadata
    metadata: TransferMetadata,
    /// Output directory
    output_dir: PathBuf,
    /// Output file path
    output_path: PathBuf,
    /// Indexes of received chunks
    received: HashSet<u32>,
    /// Set of missing chunk indices
    missing: HashSet<u32>,
    /// Whether all chunks have been received
    complete: bool,
}

impl ChunkedSender {
    /// Create a new chunked sender for the given file.
    ///
    /// Reads and splits the file into chunks in memory.
    pub fn new(file_path: &Path, config: &TransportConfig) -> TransportResult<Self> {
        let file_name = file_path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("unknown")
            .to_string();

        let file_size = file_path.metadata()?.len();
        let transfer_id = generate_transfer_id(&file_name);

        // Compute full file hash
        let full_hash = compute_file_hash(file_path)?;

        let total_chunks =
            ((file_size + config.chunk_size as u64 - 1) / config.chunk_size as u64) as u32;

        let metadata = TransferMetadata {
            transfer_id: transfer_id.clone(),
            file_name: file_name.clone(),
            file_size,
            total_chunks,
            chunk_size: config.chunk_size,
            full_hash: full_hash.clone(),
        };

        log::info!(
            "Preparing to send '{}': {} bytes, {} chunks ({} bytes each)",
            file_name,
            file_size,
            total_chunks,
            config.chunk_size
        );

        // Read and chunk the file
        let mut file = std::fs::File::open(file_path)?;
        let mut prepared_chunks = Vec::with_capacity(total_chunks as usize);
        let mut buffer = vec![0u8; config.chunk_size];

        for i in 0..total_chunks {
            let bytes_read = file.read(&mut buffer)?;
            let actual_data = &buffer[..bytes_read];
            let checksum = compute_sha256(actual_data);

            prepared_chunks.push(FileChunk {
                transfer_id: transfer_id.clone(),
                chunk_index: i,
                total_chunks,
                payload_size: bytes_read,
                data: actual_data.to_vec(),
                checksum,
            });
        }

        Ok(Self {
            file_path: file_path.to_path_buf(),
            metadata,
            prepared_chunks,
            next_index: 0,
            complete: false,
        })
    }

    /// Get the transfer metadata (for signaling).
    pub fn metadata(&self) -> &TransferMetadata {
        &self.metadata
    }

    /// Get the next chunk to send.
    ///
    /// Returns None if all chunks have been sent.
    pub fn next_chunk(&mut self) -> Option<&FileChunk> {
        if self.complete || self.next_index as usize >= self.prepared_chunks.len() {
            self.complete = true;
            return None;
        }
        let idx = self.next_index as usize;
        self.next_index += 1;
        Some(&self.prepared_chunks[idx])
    }

    /// Get the chunk at a specific index (for resume).
    pub fn get_chunk(&self, index: u32) -> Option<&FileChunk> {
        self.prepared_chunks.get(index as usize)
    }

    /// Skip to a specific chunk index (for resume).
    pub fn skip_to(&mut self, index: u32) {
        self.next_index = index;
        self.complete = false;
    }

    /// Check if all chunks have been sent.
    pub fn is_complete(&self) -> bool {
        self.complete
    }

    /// Get chunks by their indices (for resume).
    pub fn get_chunks_by_indices(&self, indices: &[u32]) -> Vec<&FileChunk> {
        indices
            .iter()
            .filter_map(|&idx| self.prepared_chunks.get(idx as usize))
            .collect()
    }

    /// Total number of chunks.
    pub fn total_chunks(&self) -> u32 {
        self.metadata.total_chunks
    }
}

impl ChunkedReceiver {
    /// Create a new chunked receiver.
    pub fn new(metadata: TransferMetadata, output_dir: &Path) -> TransportResult<Self> {
        let output_path = output_dir.join(&metadata.file_name);

        let total = metadata.total_chunks;
        let all_indices: HashSet<u32> = (0..total).collect();

        Ok(Self {
            metadata,
            output_dir: output_dir.to_path_buf(),
            output_path,
            received: HashSet::new(),
            missing: all_indices,
            complete: false,
        })
    }

    /// Create a receiver from resume information.
    pub fn from_resume(resume: ResumeInfo) -> TransportResult<Self> {
        let total = resume.total_chunks;
        let all_indices: HashSet<u32> = (0..total).collect();
        let missing: HashSet<u32> = all_indices
            .difference(&resume.received_chunks)
            .copied()
            .collect();

        let output_path = PathBuf::from(&resume.partial_path);

        Ok(Self {
            metadata: TransferMetadata {
                transfer_id: resume.transfer_id,
                file_name: String::new(), // Not critical for resume
                file_size: resume.file_size,
                total_chunks: total,
                chunk_size: 65536,
                full_hash: resume.full_hash,
            },
            output_dir: output_path.parent().unwrap_or(Path::new(".")).to_path_buf(),
            output_path,
            received: resume.received_chunks,
            missing,
            complete: false,
        })
    }

    /// Get transfer metadata.
    pub fn metadata(&self) -> &TransferMetadata {
        &self.metadata
    }

    /// Receive and validate a chunk.
    ///
    /// Returns an error if the checksum doesn't match.
    pub fn receive_chunk(&mut self, chunk: &FileChunk) -> TransportResult<()> {
        // Validate checksum
        let actual_hash = compute_sha256(&chunk.data);
        if actual_hash != chunk.checksum {
            return Err(TransportError::ChecksumMismatch {
                expected: chunk.checksum.clone(),
                actual: actual_hash,
            });
        }

        // Check duplicate
        if self.received.contains(&chunk.chunk_index) {
            log::debug!("Duplicate chunk {} ignored", chunk.chunk_index);
            return Ok(());
        }

        // Write chunk to the output file at the correct offset
        let offset = chunk.chunk_index as u64 * self.metadata.chunk_size as u64;

        if self.received.is_empty() {
            // First chunk: create/truncate the output file
            std::fs::write(&self.output_path, &chunk.data)?;
        } else {
            // Append/seek-write the chunk
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create(true)
                .open(&self.output_path)?;
            file.seek(SeekFrom::Start(offset))?;
            file.write_all(&chunk.data)?;
        }

        self.received.insert(chunk.chunk_index);
        self.missing.remove(&chunk.chunk_index);

        log::trace!(
            "Chunk {}/{} received ({}/{} remaining)",
            chunk.chunk_index + 1,
            self.metadata.total_chunks,
            self.missing.len(),
            self.metadata.total_chunks
        );

        Ok(())
    }

    /// Check if all chunks have been received.
    pub fn is_complete(&self) -> bool {
        self.missing.is_empty()
    }

    /// Get the list of missing chunk indices (for resume request).
    pub fn missing_chunks(&self) -> Vec<u32> {
        let mut missing: Vec<u32> = self.missing.iter().copied().collect();
        missing.sort();
        missing
    }

    /// Generate resume information for persistence.
    pub fn generate_resume_info(&self) -> ResumeInfo {
        ResumeInfo {
            transfer_id: self.metadata.transfer_id.clone(),
            received_chunks: self.received.clone(),
            next_expected: self.missing.iter().min().copied().unwrap_or(self.metadata.total_chunks),
            total_chunks: self.metadata.total_chunks,
            partial_path: self.output_path.to_string_lossy().to_string(),
            file_size: self.metadata.file_size,
            full_hash: self.metadata.full_hash.clone(),
        }
    }

    /// Verify the complete file hash.
    pub fn verify_complete(&self) -> TransportResult<bool> {
        if !self.is_complete() {
            return Ok(false);
        }
        let actual = compute_file_hash(&self.output_path)?;
        Ok(actual == self.metadata.full_hash)
    }

    /// Finalize the transfer: truncate to exact file size and verify.
    pub fn finalize(&self) -> TransportResult<()> {
        if !self.is_complete() {
            return Err(TransportError::Other(
                "Transfer not complete, cannot finalize".into(),
            ));
        }

        // Truncate the file to its exact size (last chunk may have padding)
        let file = std::fs::OpenOptions::new()
            .write(true)
            .open(&self.output_path)?;
        file.set_len(self.metadata.file_size)?;

        // Verify complete file hash
        if !self.verify_complete()? {
            return Err(TransportError::ChecksumMismatch {
                expected: self.metadata.full_hash.clone(),
                actual: compute_file_hash(&self.output_path)?,
            });
        }

        log::info!(
            "Transfer complete: '{}' ({} bytes, {} chunks)",
            self.metadata.file_name,
            self.metadata.file_size,
            self.metadata.total_chunks
        );

        Ok(())
    }

    /// Number of chunks received.
    pub fn received_count(&self) -> usize {
        self.received.len()
    }

    /// Number of chunks remaining.
    pub fn remaining_count(&self) -> usize {
        self.missing.len()
    }

    /// Get the output file path.
    pub fn output_path(&self) -> &Path {
        &self.output_path
    }
}

/// Generate a unique transfer ID from a file name and random component.
fn generate_transfer_id(file_name: &str) -> String {
    use rand::Rng;
    let random: u32 = rand::thread_rng().gen();
    format!("{}-{:08x}", sanitize_name(file_name), random)
}

/// Sanitize a file name for use in transfer IDs.
fn sanitize_name(name: &str) -> String {
    name.chars()
        .filter(|c| c.is_alphanumeric() || *c == '_' || *c == '-' || *c == '.')
        .take(32)
        .collect()
}

/// Compute SHA-256 hash of byte data.
pub fn compute_sha256(data: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(data);
    hex::encode(hasher.finalize())
}

/// Compute SHA-256 hash of a file.
pub fn compute_file_hash(path: &Path) -> TransportResult<String> {
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 65536];
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        hasher.update(&buffer[..n]);
    }
    Ok(hex::encode(hasher.finalize()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn create_temp_file(name: &str, content: &[u8]) -> PathBuf {
        let dir = std::env::temp_dir();
        let path = dir.join(name);
        let mut f = std::fs::File::create(&path).unwrap();
        f.write_all(content).unwrap();
        path
    }

    #[test]
    fn test_chunked_send_receive_small_file() {
        let content = b"Hello, World! This is a test file for chunked transfer.";
        let path = create_temp_file("test_chunked_small.txt", content);

        let mut config = TransportConfig::default();
        config.chunk_size = 16; // Small chunks for testing

        let mut sender = ChunkedSender::new(&path, &config).unwrap();
        let metadata = sender.metadata().clone();

        let temp_dir = std::env::temp_dir();
        let mut receiver = ChunkedReceiver::new(metadata, &temp_dir).unwrap();

        // Transfer all chunks
        let mut chunk_count = 0;
        while let Some(chunk) = sender.next_chunk() {
            receiver.receive_chunk(chunk).unwrap();
            chunk_count += 1;
        }

        assert!(sender.is_complete());
        assert!(receiver.is_complete());
        assert_eq!(chunk_count, (content.len() as f64 / 16.0).ceil() as u32);

        // Finalize and verify
        receiver.finalize().unwrap();
        let received_content = std::fs::read(receiver.output_path()).unwrap();
        assert_eq!(received_content, content);

        // Cleanup
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(receiver.output_path());
    }

    #[test]
    fn test_checksum_validation() {
        let content = b"test data";
        let path = create_temp_file("test_checksum.txt", content);

        let mut config = TransportConfig::default();
        let mut sender = ChunkedSender::new(&path, &config).unwrap();

        // Get the only chunk and corrupt it
        let chunk = sender.next_chunk().unwrap();
        let mut bad_chunk = chunk.clone();
        bad_chunk.data[0] ^= 0xFF; // Flip bits

        let temp_dir = std::env::temp_dir();
        let mut receiver =
            ChunkedReceiver::new(sender.metadata().clone(), &temp_dir).unwrap();

        let result = receiver.receive_chunk(&bad_chunk);
        assert!(result.is_err());
        match result {
            Err(TransportError::ChecksumMismatch { .. }) => {}
            _ => panic!("Expected ChecksumMismatch error"),
        }

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn test_resume_info() {
        let content = vec![0u8; 200]; // 200 bytes
        let path = create_temp_file("test_resume.bin", &content);

        let mut config = TransportConfig::default();
        config.chunk_size = 64;

        let mut sender = ChunkedSender::new(&path, &config).unwrap();

        let temp_dir = std::env::temp_dir();
        let mut receiver =
            ChunkedReceiver::new(sender.metadata().clone(), &temp_dir).unwrap();

        // Receive only first chunk
        let chunk1 = sender.next_chunk().unwrap();
        receiver.receive_chunk(chunk1).unwrap();

        // Generate resume info
        let resume = receiver.generate_resume_info();
        assert!(!resume.received_chunks.is_empty());
        assert!(!receiver.missing_chunks().is_empty());

        // Create a new receiver from resume info
        let mut resumed = ChunkedReceiver::from_resume(resume).unwrap();
        assert_eq!(resumed.received_count(), 1);

        // Receive remaining chunks
        while let Some(chunk) = sender.next_chunk() {
            resumed.receive_chunk(chunk).unwrap();
        }

        assert!(resumed.is_complete());
        resumed.finalize().unwrap();

        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(resumed.output_path());
    }

    #[test]
    fn test_compute_sha256() {
        assert_eq!(
            compute_sha256(b"hello"),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
    }

    #[test]
    fn test_generate_transfer_id() {
        let id = generate_transfer_id("test.pdf");
        assert!(id.starts_with("test.pdf-"));
        assert_eq!(id.len(), "test.pdf-".len() + 8);
    }
}
