"""
Write-Ahead Journal for HomeFS

Implements crash-resistant journaling for file operations.
All writes are logged before being applied, allowing recovery
after crashes or power loss.
"""

import json
import logging
import os
import struct
import time
import uuid
import zlib
from dataclasses import dataclass, asdict
from enum import Enum
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)


class OpType(Enum):
    """Journal operation types."""

    CREATE = "create"
    WRITE = "write"
    DELETE = "delete"
    RENAME = "rename"
    CHMOD = "chmod"
    CHOWN = "chown"
    TRUNCATE = "truncate"
    MKDIR = "mkdir"
    RMDIR = "rmdir"
    SYMLINK = "symlink"


@dataclass
class Transaction:
    """Represents a single journal transaction."""

    txn_id: str  # UUID
    timestamp: float  # Unix timestamp
    op_type: OpType
    path: str
    old_path: Optional[str] = None  # For rename
    offset: Optional[int] = None  # For write
    length: Optional[int] = None  # For write
    data: Optional[bytes] = None  # For write, create
    mode: Optional[int] = None  # For chmod, create
    uid: Optional[int] = None  # For chown
    gid: Optional[int] = None  # For chown
    size: Optional[int] = None  # For truncate
    target: Optional[str] = None  # For symlink
    checksum: Optional[int] = None  # CRC32 of data

    def __post_init__(self):
        """Calculate checksum if data present."""
        if self.data and self.checksum is None:
            self.checksum = zlib.crc32(self.data)

    def verify_checksum(self) -> bool:
        """Verify data integrity."""
        if self.data and self.checksum:
            return zlib.crc32(self.data) == self.checksum
        return True

    def to_dict(self) -> dict:
        """Convert to dictionary for serialization."""
        d = asdict(self)
        d["op_type"] = self.op_type.value
        # Convert bytes to hex string for JSON
        if d["data"]:
            d["data"] = d["data"].hex()
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "Transaction":
        """Create from dictionary."""
        d = d.copy()
        d["op_type"] = OpType(d["op_type"])
        # Convert hex string back to bytes
        if d["data"]:
            d["data"] = bytes.fromhex(d["data"])
        return cls(**d)


@dataclass
class Checkpoint:
    """Journal checkpoint marker."""

    checkpoint_id: int
    timestamp: float
    last_synced_txn: str  # UUID of last synced transaction


class Journal:
    """
    Write-Ahead Journal for HomeFS.

    Features:
    - Atomic transactions
    - Crash recovery
    - Checkpointing
    - Journal compaction
    - Batch operations
    """

    MAGIC = 0x484F4D45  # "HOME"
    VERSION = 1

    def __init__(self, journal_path: str, max_size: int = 1024**3):
        """
        Initialize journal.

        Args:
            journal_path: Path to journal file
            max_size: Maximum journal size before compaction (bytes)
        """
        self.journal_path = Path(journal_path)
        self.max_size = max_size

        # In-memory state
        self.transactions: list[Transaction] = []
        self.checkpoints: list[Checkpoint] = []
        self.next_checkpoint_id = 1

        # Ensure directory exists
        self.journal_path.parent.mkdir(parents=True, exist_ok=True)

        # Load existing journal
        if self.journal_path.exists():
            self._load()
        else:
            self._create_new()

        logger.info(f"Journal initialized: {self.journal_path}")

    def _create_new(self) -> None:
        """Create new journal file."""
        with open(self.journal_path, "wb") as f:
            # Write header
            f.write(struct.pack("<I", self.MAGIC))
            f.write(struct.pack("<I", self.VERSION))
            f.write(struct.pack("<Q", 0))  # Transaction count
            f.write(struct.pack("<I", 0))  # Header checksum (placeholder)

        logger.info("Created new journal file")

    def _load(self) -> None:
        """Load journal from disk."""
        try:
            with open(self.journal_path, "rb") as f:
                # Read header
                magic = struct.unpack("<I", f.read(4))[0]
                if magic != self.MAGIC:
                    raise ValueError(f"Invalid journal magic: {magic:x}")

                version = struct.unpack("<I", f.read(4))[0]
                if version != self.VERSION:
                    raise ValueError(f"Unsupported journal version: {version}")

                txn_count = struct.unpack("<Q", f.read(8))[0]
                header_checksum = struct.unpack("<I", f.read(4))[0]

                logger.info(f"Loading journal: {txn_count} transactions")

                # Read transactions
                while True:
                    # Read entry type (1 byte)
                    entry_type_bytes = f.read(1)
                    if not entry_type_bytes:
                        break

                    entry_type = entry_type_bytes[0]

                    if entry_type == 0x01:  # Transaction
                        txn = self._read_transaction(f)
                        if txn and txn.verify_checksum():
                            self.transactions.append(txn)
                        else:
                            logger.warning("Skipping corrupted transaction")

                    elif entry_type == 0x02:  # Checkpoint
                        checkpoint = self._read_checkpoint(f)
                        if checkpoint:
                            self.checkpoints.append(checkpoint)
                            self.next_checkpoint_id = checkpoint.checkpoint_id + 1

                logger.info(
                    f"Loaded {len(self.transactions)} transactions, "
                    f"{len(self.checkpoints)} checkpoints"
                )

        except Exception as e:
            logger.error(f"Failed to load journal: {e}")
            # Try recovery
            self._recover()

    def _read_transaction(self, f) -> Optional[Transaction]:
        """Read single transaction from file."""
        try:
            # Read length
            length = struct.unpack("<I", f.read(4))[0]

            # Read JSON data
            json_data = f.read(length)
            txn_dict = json.loads(json_data.decode("utf-8"))

            return Transaction.from_dict(txn_dict)

        except Exception as e:
            logger.error(f"Failed to read transaction: {e}")
            return None

    def _read_checkpoint(self, f) -> Optional[Checkpoint]:
        """Read checkpoint from file."""
        try:
            checkpoint_id = struct.unpack("<Q", f.read(8))[0]
            timestamp = struct.unpack("<d", f.read(8))[0]

            txn_id_len = struct.unpack("<I", f.read(4))[0]
            txn_id = f.read(txn_id_len).decode("utf-8")

            return Checkpoint(
                checkpoint_id=checkpoint_id,
                timestamp=timestamp,
                last_synced_txn=txn_id,
            )

        except Exception as e:
            logger.error(f"Failed to read checkpoint: {e}")
            return None

    def _recover(self) -> None:
        """Attempt to recover from corrupted journal."""
        logger.warning("Attempting journal recovery")

        # Strategy: read as much as possible, discard corrupted entries
        # For now, just create new journal
        backup_path = self.journal_path.with_suffix(".corrupt")
        self.journal_path.rename(backup_path)
        logger.info(f"Moved corrupted journal to {backup_path}")

        self._create_new()

    def append(self, transaction: Transaction) -> None:
        """
        Append transaction to journal.

        Args:
            transaction: Transaction to append
        """
        # Add to in-memory list
        self.transactions.append(transaction)

        # Write to disk
        with open(self.journal_path, "ab") as f:
            # Entry type: 0x01 = transaction
            f.write(b"\x01")

            # Serialize transaction
            txn_dict = transaction.to_dict()
            json_data = json.dumps(txn_dict).encode("utf-8")

            # Write length + data
            f.write(struct.pack("<I", len(json_data)))
            f.write(json_data)

        logger.debug(f"Appended transaction: {transaction.op_type.value} {transaction.path}")

        # Check if compaction needed
        if self.journal_path.stat().st_size > self.max_size:
            self._compact()

    def checkpoint(self, last_synced_txn: str) -> None:
        """
        Create checkpoint marker.

        Args:
            last_synced_txn: UUID of last successfully synced transaction
        """
        checkpoint = Checkpoint(
            checkpoint_id=self.next_checkpoint_id,
            timestamp=time.time(),
            last_synced_txn=last_synced_txn,
        )

        self.checkpoints.append(checkpoint)
        self.next_checkpoint_id += 1

        # Write to disk
        with open(self.journal_path, "ab") as f:
            # Entry type: 0x02 = checkpoint
            f.write(b"\x02")

            f.write(struct.pack("<Q", checkpoint.checkpoint_id))
            f.write(struct.pack("<d", checkpoint.timestamp))

            txn_id_bytes = checkpoint.last_synced_txn.encode("utf-8")
            f.write(struct.pack("<I", len(txn_id_bytes)))
            f.write(txn_id_bytes)

        logger.info(f"Created checkpoint {checkpoint.checkpoint_id}")

    def get_pending_transactions(self) -> list[Transaction]:
        """
        Get transactions that haven't been synced yet.

        Returns transactions after the last checkpoint.
        """
        if not self.checkpoints:
            # No checkpoints, all transactions are pending
            return self.transactions.copy()

        # Find last checkpoint
        last_checkpoint = self.checkpoints[-1]

        # Find index of last synced transaction
        last_synced_idx = -1
        for i, txn in enumerate(self.transactions):
            if txn.txn_id == last_checkpoint.last_synced_txn:
                last_synced_idx = i
                break

        # Return transactions after last synced
        return self.transactions[last_synced_idx + 1:]

    def _compact(self) -> None:
        """
        Compact journal by removing synced transactions.

        Keeps only transactions after last checkpoint.
        """
        logger.info("Compacting journal")

        pending = self.get_pending_transactions()

        # Create new journal file
        new_path = self.journal_path.with_suffix(".new")
        old_path = self.journal_path

        # Write compacted journal
        self.journal_path = new_path
        self._create_new()

        # Re-write pending transactions
        for txn in pending:
            self.append(txn)

        # Re-write last checkpoint
        if self.checkpoints:
            last_checkpoint = self.checkpoints[-1]
            self.checkpoint(last_checkpoint.last_synced_txn)

        # Replace old journal
        old_path.replace(new_path.with_suffix(".old"))
        new_path.rename(old_path)
        self.journal_path = old_path

        logger.info(f"Journal compacted: {len(pending)} pending transactions")

    def create_transaction(
        self,
        op_type: OpType,
        path: str,
        **kwargs
    ) -> Transaction:
        """
        Create and append a new transaction.

        Args:
            op_type: Type of operation
            path: File path
            **kwargs: Additional transaction parameters

        Returns:
            Created transaction
        """
        txn = Transaction(
            txn_id=str(uuid.uuid4()),
            timestamp=time.time(),
            op_type=op_type,
            path=path,
            **kwargs
        )

        self.append(txn)
        return txn

    def replay(self, backend, start_from: Optional[str] = None) -> int:
        """
        Replay journal transactions to backend storage.

        Args:
            backend: Storage backend with apply_transaction() method
            start_from: UUID of transaction to start from (None = start from beginning)

        Returns:
            Number of transactions replayed
        """
        transactions = self.get_pending_transactions() if start_from is None else self.transactions

        # Find start index
        start_idx = 0
        if start_from:
            for i, txn in enumerate(transactions):
                if txn.txn_id == start_from:
                    start_idx = i + 1
                    break

        replayed = 0
        for txn in transactions[start_idx:]:
            try:
                backend.apply_transaction(txn)
                replayed += 1
            except Exception as e:
                logger.error(f"Failed to replay transaction {txn.txn_id}: {e}")
                # Continue with next transaction

        logger.info(f"Replayed {replayed} transactions")
        return replayed

    def clear(self) -> None:
        """Clear all transactions and checkpoints."""
        self.transactions.clear()
        self.checkpoints.clear()
        self.next_checkpoint_id = 1
        self._create_new()
        logger.info("Journal cleared")

    def get_stats(self) -> dict:
        """Get journal statistics."""
        pending = self.get_pending_transactions()
        file_size = self.journal_path.stat().st_size if self.journal_path.exists() else 0

        return {
            "total_transactions": len(self.transactions),
            "pending_transactions": len(pending),
            "checkpoints": len(self.checkpoints),
            "file_size": file_size,
            "max_size": self.max_size,
            "usage_percent": (file_size / self.max_size) * 100 if self.max_size > 0 else 0,
        }
