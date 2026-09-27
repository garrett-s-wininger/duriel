/*
 * NOTE(garrett): EDK2 reserves this much space in its toolchain during GenFW
 * conversion from ELF over to PE32+/COFF for the EFI image. We reserve it
 * here so program text is appropriately placed beyond the reserved section at
 * the next page-aligned address.
 */
PECOFF_HEADER_SIZE = 0x240;

PHDRS {
	text    PT_LOAD    FLAGS(5);
	data    PT_LOAD    FLAGS(6);
	dynamic PT_DYNAMIC FLAGS(4);
}

SECTIONS {
	. = PECOFF_HEADER_SIZE;

	.text : ALIGN(0x1000) {
		*(.text .text.* .stub .gnu.linkonce.t.*)
		*(.rodata .rodata.* .gnu.linkonce.r.*)
		*(.got .got.*)
	} :text

	.data : ALIGN(ALIGNOF(.text)) {
		*(.bss .bss.*)
		*(.data .data.* .gnu.linkonce.d.*)
	} :data

	.dynamic : ALIGN(ALIGNOF(.data)) {
		*(.dynamic .dynamic.*)
	} :data :dynamic

	.rela (INFO) : {
		*(.rela .rela.*)
	}

	/DISCARD/ : {
		*(.comment)
		*(.dynstr .dynsym)
		*(.gnu.hash .hash)
		*(.note.GNU-stack)
		*(.gnu_debuglink)
		*(.interp)
	}
}
