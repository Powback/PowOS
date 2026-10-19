package dev.omalauncher.shell

/** Third-party notices: settings' licenses screen (shell/ui/screens.tsx), its texts in assets/licenses. */
object Licenses {
    /**
     * What the app ships that others wrote. [license] names a text in assets/licenses; [notice] is
     * the component's copyright line, which MIT and BSD need next to the text. [source] is where the
     * code is: for proot and talloc that's the offer of source their licenses ask for.
     */
    class Component(
        val name: String,
        val use: String,
        val license: String,
        val notice: String,
        val url: String,
        val source: String? = null,
    )

    private const val APACHE = "apache-2.0"

    // proot is built from Termux's source with our patches (patches/proot), talloc and libandroid-shmem
    // are Termux's builds (scripts/fetch-proot.sh); libproot.so and libtalloc.so are patched to need
    // libtalloc.so instead of libtalloc.so.2, so the notice says so. The source links name the versions
    // that script pins; change them together.
    val COMPONENTS =
        listOf(
            Component(
                "PRoot",
                "runs the optional Linux system",
                "gpl-2.0",
                "Copyright (C) 2015 STMicroelectronics. Built from Termux's 5.1.107.96 with omalauncher's patches; the binary's libtalloc.so.2 dependency is renamed to libtalloc.so.",
                "https://proot-me.github.io",
                source = "https://github.com/SimonSchubert/omalauncher/tree/main/patches/proot",
            ),
            Component(
                "talloc",
                "memory allocator used by PRoot",
                "lgpl-3.0",
                "Copyright (C) Andrew Tridgell 2004, Stefan Metzmacher 2006. Termux build of 2.5.0, renamed to libtalloc.so. The LGPL adds to the GPL 3.0 below it.",
                "https://talloc.samba.org",
                source = "https://www.samba.org/ftp/talloc/talloc-2.5.0.tar.gz",
            ),
            Component(
                "libandroid-shmem",
                "shared memory for PRoot",
                "bsd-3-clause",
                "Copyright (c) 2013, Sergii Pylypenko\nCopyright (c) 2017, Fredrik Fornwall\nAll rights reserved.",
                "https://github.com/termux/libandroid-shmem",
                source = "https://github.com/termux/libandroid-shmem/tree/v0.7",
            ),
            Component(
                "Omarchy",
                "theme colors bundled for first run",
                "mit",
                "Copyright (c) David Heinemeier Hansson",
                "https://github.com/omacom/omarchy",
            ),
            Component("Nerd Fonts", "symbol font", "mit", "Copyright (c) 2014 Ryan L McIntyre", "https://www.nerdfonts.com"),
            Component(
                "Weather Icons",
                "weather glyphs in the symbol font",
                "ofl-1.1",
                "Copyright (c) Erik Flowers. Licensed under the SIL Open Font License 1.1.",
                "https://erikflowers.github.io/weather-icons/",
            ),
            Component(
                "Material Design Icons",
                "glyphs in the symbol font",
                APACHE,
                "Copyright (c) Pictogrammers",
                "https://pictogrammers.com/library/mdi/",
            ),
            Component(
                "Compose Multiplatform",
                "user interface",
                APACHE,
                "Copyright 2020-2026 JetBrains s.r.o. and respective authors and developers",
                "https://github.com/JetBrains/compose-multiplatform",
            ),
            Component(
                "Android Jetpack",
                "activity, Compose and other AndroidX libraries",
                APACHE,
                "Copyright The Android Open Source Project",
                "https://developer.android.com/jetpack/androidx",
            ),
            Component(
                "Kotlin and kotlinx.coroutines",
                "language runtime",
                APACHE,
                "Copyright 2010-2026 JetBrains s.r.o. and Kotlin Programming Language contributors",
                "https://kotlinlang.org",
            ),
            Component(
                "Apache Commons Compress",
                "unpacks downloads",
                APACHE,
                "Apache Commons Compress\nCopyright 2002-2026 The Apache Software Foundation\n\n" +
                    "This product includes software developed at The Apache Software Foundation (https://www.apache.org/).",
                "https://commons.apache.org/proper/commons-compress/",
            ),
            Component("AndroidSVG", "draws SVG icons", APACHE, "Copyright 2013 Paul LeBeau, Cave Rock Software Ltd.", "https://bigbadaboom.github.io/androidsvg/"),
            Component("Termux terminal emulator and view", "draws PowOS terminals in home-screen tiles", APACHE, "Copyright Termux developers", "https://github.com/termux/termux-app"),
            Component("ZXing", "draws the QR codes widgets are shared with", APACHE, "Copyright 2007-2025 ZXing authors", "https://github.com/zxing/zxing"),
            Component("JSON-java", "reads and writes JSON", "public-domain", "Public Domain.", "https://github.com/stleary/JSON-java"),
        )
}
