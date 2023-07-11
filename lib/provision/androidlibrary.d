module provision.androidlibrary;

import core.exception;
import core.memory;
import core.stdc.errno;
import core.stdc.stdint;
import core.stdc.stdlib;
import core.sys.linux.elf;
import core.sys.linux.link;
import core.sys.posix.sys.mman;
import std.algorithm;
import std.conv;
import std.experimental.allocator;
import std.experimental.allocator.mallocator;
import std.experimental.allocator.mmap_allocator;
import std.functional;
import std.mmfile;
import std.path;
import std.random;
import std.range;
import std.string;
import std.traits;

import slf4d;

public class AndroidLibrary {
    package MmFile elfFile;
    package void[] allocation;

    package char[] sectionNamesTable;
    package char[] dynamicStringTable;
    package ElfW!"Sym"[] dynamicSymbolTable;
    package SymbolHashTable hashTable;
    package AndroidLibrary[] loadedLibraries;

    public void*[string] hooks;

    private ElfW!"Shdr"[] relocationSections;

    public this(string libraryName, void*[string] hooks = null) {
        elfFile = new MmFile(libraryName);
        if (hooks) this.hooks = hooks;

        auto elfHeader = elfFile.identify!(ElfW!"Ehdr")(0);
        auto programHeaders = elfFile.identifyArray!(ElfW!"Phdr")(elfHeader.e_phoff, elfHeader.e_phnum);

        size_t minimum = size_t.max;
        size_t maximumFile = size_t.min;
        size_t maximumMemory = size_t.min;

        size_t headerStart;
        size_t headerEnd;
        size_t headerMemoryEnd;

        foreach (programHeader; programHeaders) {
            if (programHeader.p_type == PT_LOAD) {
                headerStart = programHeader.p_vaddr;
                headerEnd = programHeader.p_vaddr + programHeader.p_filesz;
                headerMemoryEnd = programHeader.p_vaddr + programHeader.p_memsz;

                if (headerStart < minimum) {
                    minimum = headerStart;
                }
                if (headerEnd > maximumFile) {
                    maximumFile = headerEnd;
                }
                if (headerMemoryEnd > maximumMemory) {
                    maximumMemory = headerMemoryEnd;
                }
            }
        }

        auto alignedMinimum = pageFloor(minimum);
        auto alignedMaximumMemory = pageCeil(maximumMemory);

        auto allocSize = alignedMaximumMemory - alignedMinimum;
        auto mmapped_alloc = mmap(null, allocSize, PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANON, -1, 0);
        if (mmapped_alloc == MAP_FAILED) {
            throw new LoaderException("Cannot allocate the memory: " ~ to!string(errno));
        }
        memoryTable[MemoryBlock(cast(size_t) mmapped_alloc, cast(size_t) mmapped_alloc + allocSize)] = this;
        getLogger().traceF!"Allocating %x - %x for %s"(cast(size_t) mmapped_alloc, cast(size_t) mmapped_alloc + allocSize, libraryName);
        allocation = mmapped_alloc[0..allocSize];

        size_t fileStart;
        size_t fileEnd;

        foreach (programHeader; programHeaders) {
            if (programHeader.p_type == PT_LOAD) {
                headerStart = programHeader.p_vaddr;
                headerEnd = programHeader.p_vaddr + programHeader.p_filesz;
                fileStart = programHeader.p_offset;
                fileEnd = programHeader.p_offset + programHeader.p_filesz;

                allocation[headerStart - alignedMinimum..headerEnd - alignedMinimum] = elfFile[fileStart..fileEnd];

                auto protectionResult = mprotect(allocation.ptr + pageFloor(headerStart), pageCeil(headerEnd) - pageFloor(headerStart), programHeader.memoryProtection());

                if (protectionResult != 0) {
                    throw new LoaderException("Cannot protect the memory correctly.");
                }
            }
        }

        auto sectionHeaders = elfFile.identifyArray!(ElfW!"Shdr")(elfHeader.e_shoff, elfHeader.e_shnum);
        auto sectionStrTable = sectionHeaders[elfHeader.e_shstrndx];
        sectionNamesTable = cast(char[]) elfFile[sectionStrTable.sh_offset..sectionStrTable.sh_offset + sectionStrTable.sh_size];

        foreach (sectionHeader; sectionHeaders) {
            switch (sectionHeader.sh_type) {
                case SHT_DYNSYM:
                    dynamicSymbolTable = elfFile.identifyArray!(ElfW!"Sym")(sectionHeader.sh_offset, sectionHeader.sh_size / ElfW!"Sym".sizeof);
                    break;
                case SHT_STRTAB:
                    if (getSectionName(sectionHeader) == ".dynstr")
                        dynamicStringTable = cast(char[]) elfFile[sectionHeader.sh_offset..sectionHeader.sh_offset + sectionHeader.sh_size];
                    break;
                case SHT_GNU_HASH:
                    hashTable = new GnuHashTable(cast(ubyte[]) elfFile[sectionHeader.sh_offset..sectionHeader.sh_offset + sectionHeader.sh_size]);
                    break;
                case SHT_HASH:
                    if (!hashTable) {
                        hashTable = new ElfHashTable(cast(ubyte[]) elfFile[sectionHeader.sh_offset..sectionHeader.sh_offset + sectionHeader.sh_size]);
                    }
                    break;
                case SHT_REL:
                    this.relocate!(ElfW!"Rel")(sectionHeader);
                    relocationSections ~= sectionHeader;
                    break;
                case SHT_RELA:
                    this.relocate!(ElfW!"Rela")(sectionHeader);
                    relocationSections ~= sectionHeader;
                    break;
                default:
                    break;
            }
        }
    }

    ~this() {
        foreach (library; loadedLibraries) {
            destroy(library);
        }

        if (allocation) {
            munmap(allocation.ptr, allocation.length);
        }
    }

    public void relocate() {
        foreach (relocationSection; relocationSections) {
            switch (relocationSection.sh_type) {
                case SHT_REL:
                    this.relocate!(ElfW!"Rel")(relocationSection);
                    break;
                case SHT_RELA:
                    this.relocate!(ElfW!"Rela")(relocationSection);
                    break;
                default:
                    break;
            }
        }
    }

    private void relocate(RelocationType)(ref ElfW!"Shdr" shdr) {
        auto relocations = this.elfFile.identifyArray!(RelocationType)(shdr.sh_offset, shdr.sh_size / RelocationType.sizeof);
        auto allocation = cast(ubyte[]) allocation;

        foreach (relocation; relocations) {
            auto relocationType = ELFW!"R_TYPE"(relocation.r_info);
            auto symbolIndex = ELFW!"R_SYM"(relocation.r_info);

            auto offset = relocation.r_offset;
            size_t addend;
            static if (__traits(hasMember, relocation, "r_addend")) {
                addend = relocation.r_addend;
            } else {
                if (relocationType == R_386_JUMP_SLOT) {
                    addend = 0;
                } else {
                    addend = *cast(size_t*) (cast(size_t) allocation.ptr + offset);
                }
            }
            auto symbol = getSymbolImplementation(getSymbolName(dynamicSymbolTable[symbolIndex]));

            auto location = cast(size_t*) (cast(size_t) allocation.ptr + offset);

            switch (relocationType) {
                case R_GENERIC!"RELATIVE":
                    *location = cast(size_t) allocation.ptr + addend;
                    break;
                case R_GENERIC!"GLOB_DAT":
                    *location = cast(size_t) (symbol + addend);
                    break;
                case R_GENERIC!"JUMP_SLOT":
                    *location = cast(size_t) (symbol);
                    break;
                case R_GENERIC_NATIVE_ABS:
                    *location = cast(size_t) (symbol + addend);
                    break;
                default:
                    throw new LoaderException("Unknown relocation type: " ~ to!string(relocationType));
            }
        }
    }

    private string getSymbolName(ElfW!"Sym" symbol) {
        return cast(string) fromStringz(&dynamicStringTable[symbol.st_name]);
    }

    private string getSectionName(ElfW!"Shdr" section) {
        return cast(string) fromStringz(&sectionNamesTable[section.sh_name]);
    }

    void* getSymbolImplementation(string symbolName) {
        void** hook = symbolName in hooks;
        if (hook) {
            return *hook;
        }

        import provision.symbols;
        return lookupSymbol(symbolName);
    }

    void* load(string symbolName) {
        ElfW!"Sym" sym;
        if (hashTable) {
            sym = hashTable.lookup(symbolName, this);
        } else {
            foreach (symbol; dynamicSymbolTable) {
                if (getSymbolName(symbol) == symbolName) {
                    sym = symbol;
                    break;
                }
            }
        }
        return cast(void*) (cast(size_t) allocation.ptr + sym.st_value);
    }
}

private struct MemoryBlock {
    size_t start;
    size_t end;
}

private __gshared AndroidLibrary[MemoryBlock] memoryTable;
AndroidLibrary memoryOwner(size_t address) {
    foreach(memoryBlock; memoryTable.keys()) {
        if (address > memoryBlock.start && address < memoryBlock.end) {
            return memoryTable[memoryBlock];
        }
    }

    getLogger().error("Cannot find the parent library! Expect bugs!");
    return null;
}

import core.sys.linux.execinfo;
pragma(inline, true) AndroidLibrary rootLibrary() {
    enum MAXFRAMES = 4;
    void*[MAXFRAMES] callstack;
    auto numframes = backtrace(callstack.ptr, MAXFRAMES);
    return memoryOwner(cast(size_t) callstack[numframes - 1]);
}

interface SymbolHashTable {
    ElfW!"Sym" lookup(string symbolName, AndroidLibrary library);
}

package class ElfHashTable: SymbolHashTable {
    struct ElfHashTableStruct {
        uint nbucket;
        uint nchain;
    }

    ElfHashTableStruct table;

    uint[] buckets;
    uint[] chain;

    this(ubyte[] tableData) {
        table = *cast(ElfHashTableStruct*) tableData.ptr;
        auto chainLocation = ElfHashTableStruct.sizeof + table.nbucket * uint.sizeof;

        buckets = cast(uint[]) tableData[ElfHashTableStruct.sizeof..chainLocation];
        chain = cast(uint[]) tableData[chainLocation..$];
    }

    static uint hash(string name) {
        uint h = 0, g;

        foreach (c; name) {
            h = 16 * h + c;
            h ^= h >> 24 & 0xf0;
        }

        return h & 0xfffffff;
    }

    ElfW!"Sym" lookup(string symbolName, AndroidLibrary library) {
        auto targetHash = hash(symbolName);

        scope ElfW!"Sym" symbol;
        for (uint i = buckets[targetHash % table.nbucket]; i; i = chain[i]) {
            symbol = library.dynamicSymbolTable[i];
            if (symbolName == library.getSymbolName(symbol)) {
                return symbol;
            }
        }

        throw new LoaderException("Symbol not found: " ~ symbolName);
    }
}

package class GnuHashTable: SymbolHashTable {
    struct GnuHashTableStruct {
        uint nbuckets;
        uint symoffset;
        uint bloomSize;
        uint bloomShift;
    }

    GnuHashTableStruct table;
    size_t[] bloom;
    uint[] buckets;
    uint[] chain;

    this(ubyte[] tableData) {
        table = *cast(GnuHashTableStruct*) tableData.ptr;
        auto bucketsLocation = GnuHashTableStruct.sizeof + table.bloomSize * (size_t.sizeof / ubyte.sizeof);
        auto chainLocation = bucketsLocation + table.nbuckets * (uint.sizeof / ubyte.sizeof);

        bloom = cast(size_t[]) tableData[GnuHashTableStruct.sizeof..bucketsLocation];
        buckets = cast(uint[]) tableData[bucketsLocation..chainLocation];
        chain = cast(uint[]) tableData[chainLocation..$];
    }

    static uint hash(string name) {
        uint h = 5381;

        foreach (c; name) {
            h = (h << 5) + h + c;
        }

        return h;
    }

    ElfW!"Sym" lookup(string symbolName, AndroidLibrary library) {
        auto targetHash = hash(symbolName);
        auto bucket = buckets[targetHash % table.nbuckets];

        if (bucket < table.symoffset) {
            throw new LoaderException("Symbol not found: " ~ symbolName);
        }

        auto chain_index = bucket - table.symoffset;
        targetHash &= ~1;
        auto chains = chain[chain_index..$];
        auto dynsyms = library.dynamicSymbolTable[bucket..$];
        foreach (hash, symbol; zip(chains, dynsyms)) {
            if ((hash &~ 1) == targetHash && symbolName == library.getSymbolName(symbol)) {
                return symbol;
            }

            if (hash & 1) {
                break;
            }
        }

        throw new LoaderException("Symbol not found: " ~ symbolName);
    }
}

private size_t pageMask;

shared static this()
{
    pageMask = ~(pageSize - 1);
}

int memoryProtection(ref ElfW!"Phdr" phdr)
{
    int prot = 0;
    if (phdr.p_flags & PF_R) {
        prot |= PROT_READ;
    }
    if (phdr.p_flags & PF_W) {
        prot |= PROT_WRITE;
    }
    if (phdr.p_flags & PF_X) {
        prot |= PROT_EXEC;
    }

    return prot;
}

template ELFW(string func) {
    alias ELFW = mixin("ELF" ~ to!string(size_t.sizeof * 8) ~ "_" ~ func);
}

version (X86_64) {
    private enum string relocationArch = "X86_64";
    private enum R_GENERIC_NATIVE_ABS = R_X86_64_64;
} else version (X86) {
    private enum string relocationArch = "386";
    private enum R_GENERIC_NATIVE_ABS = R_386_32;
} else version (AArch64) {
    private enum string relocationArch = "AARCH64";
    private enum R_GENERIC_NATIVE_ABS = R_AARCH64_ABS64;
} else version (ARM) {
    private enum string relocationArch = "ARM";
    private enum R_GENERIC_NATIVE_ABS = R_ARM_ABS32;
}

alias R_386_JUMP_SLOT = R_386_JMP_SLOT;

template R_GENERIC(string relocationType) {
    enum R_GENERIC = mixin("R_" ~ relocationArch ~ "_" ~ relocationType);
}

size_t pageFloor(size_t number) {
    return number & pageMask;
}

size_t pageCeil(size_t number) {
    return (number + pageSize - 1) & pageMask;
}

RetType[] identifyArray(RetType, FromType)(FromType obj, size_t offset, size_t length) {
    return (cast(RetType[]) obj[offset..offset + (RetType.sizeof * length)]).ptr[0..length];
}

RetType identify(RetType, FromType)(FromType obj, size_t offset) {
    return obj[offset..offset + RetType.sizeof].reinterpret!(RetType);
}

RetType reinterpret(RetType, FromType)(FromType[] obj) {
    return (cast(RetType[]) obj)[0];
}

class LoaderException: Exception {
    this(string message, string file = __FILE__, size_t line = __LINE__) {
        super("Cannot load library: " ~ message, file, line);
    }
}

class UndefinedSymbolException: Exception {
    this(string file = __FILE__, size_t line = __LINE__) {
        super("An undefined symbol has been called!", file, line);
    }
}
