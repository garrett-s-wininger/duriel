pub const PageMapLevel4Entry = packed struct(u64) { _low: u12, page_directory_pointer_address: u40, _high: u12 };
pub const PageMapLevel4Table = [512]PageMapLevel4Entry;

pub const PageDirectoryPointerEntry = packed struct(u64) { _low: u12, page_directory_address: u40, _high: u12 };
pub const PageDirectoryPointerTable = [512]PageDirectoryPointerEntry;

pub const PageDirectoryEntry = packed struct(u64) { _low: u12, page_table_address: u40, _high: u12 };
pub const PageDirectoryTable = [512]PageDirectoryEntry;

pub const PageTableEntry = packed struct(u64) { _low: u12, physical_address: u40, _high: u12 };
pub const PageTable = [512]PageTableEntry;

pub const present = 1 << 0;
pub const user_accessible = 1 << 2;
pub const read_write = 1 << 1;
pub const large_page = 1 << 7;
