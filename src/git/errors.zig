pub const GitError = error{
    GitNotInstalled,
    AbnormalExit,
    AbnormalReference,
    FilesystemError,
    NotFound,
    OutOfMemory,
};
