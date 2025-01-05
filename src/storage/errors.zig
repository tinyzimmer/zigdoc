pub const StorageError = error{
    StorageNotFound,
    InvalidStoragePath,
    StorageReadFailed,
    StorageWriteFailed,
    FilesystemError,
    OutOfMemory,
};
