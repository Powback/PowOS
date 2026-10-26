package dev.omalauncher.widgets.cli

import dev.omalauncher.widgets.lang.Bool
import dev.omalauncher.widgets.lang.Budget
import dev.omalauncher.widgets.lang.Builtins
import dev.omalauncher.widgets.lang.Col
import dev.omalauncher.widgets.lang.Compiler
import dev.omalauncher.widgets.lang.Env
import dev.omalauncher.widgets.lang.Global
import dev.omalauncher.widgets.lang.Gradient
import dev.omalauncher.widgets.lang.Host
import dev.omalauncher.widgets.lang.Json
import dev.omalauncher.widgets.lang.Lst
import dev.omalauncher.widgets.lang.Null
import dev.omalauncher.widgets.lang.Num
import dev.omalauncher.widgets.lang.Obj
import dev.omalauncher.widgets.lang.Program
import dev.omalauncher.widgets.lang.Str
import dev.omalauncher.widgets.lang.Value
import dev.omalauncher.widgets.lang.WNode
import dev.omalauncher.widgets.lang.WidgetError
import dev.omalauncher.widgets.lang.bool
import java.io.File
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.time.Duration

/**
 * `owl trees`: a widget's node trees as the web shell draws them (shell/ui/owl.tsx), off the phone - for the widget
 * preview (shell/dev/preview.sh), which renders every widget at every size it allows. The same walk and JSON as the
 * app's WidgetTree.kt (keep the two in step), over a host of its own instead of the app's WidgetInstance: the sources
 * take mock values from a data file (a `{"seq": [...]}` is fed one value per update, so history() and prev() fill),
 * `clock` is now, and with --live an http() source is fetched for real. Android services and guest commands are
 * only ever the data file's.
 *
 *   owl trees <file.owl> --theme <colors.toml> --variants <variants.json> [--data <data.json>] [--live]
 *   owl trees --batch <batch.json>       [{ "file", "theme", "data", "live", "variants", "out" }]: each to its "out"
 *
 * variants.json: [{ "id", "cols", "rows", "w", "h", "screen": [w, h] | null, "canvas": { "<element id>": [w, h] } }]
 * (w/h: the tile's size in dp; canvas: sizes the page measured, else 100x100 as on the phone before it reports).
 * Prints { "<id>": tree, "<id>#screen": tree, "meta": { minSize, size }, "errors": [...] }.
 */
internal fun trees(args: List<String>): Int {
    fun opt(name: String) = args.indexOf(name).takeIf { it >= 0 }?.let { args.getOrNull(it + 1) }
    // --batch <batch.json>: [{ "file", "theme", "data", "live", "variants": [...], "out" }] - one JVM for a whole preview.
    opt("--batch")?.let { batch ->
        var failed = 0
        for (job in (Json.parse(File(batch).readText()) as Lst).items.map { (it as Obj).fields }) {
            val text =
                try {
                    trees(
                        File(job["file"].toString()).readText(),
                        job["theme"]?.takeIf { it != Null }?.let { toml(File(it.toString()).readText()) }.orEmpty(),
                        job["data"]?.takeIf { it != Null }?.let { File(it.toString()) }?.takeIf { it.exists() }?.let { Json.parse(it.readText()) as? Obj }?.fields.orEmpty(),
                        (job["variants"] as Lst).items.map { it as Obj },
                        job["live"]?.truthy == true,
                    )
                } catch (e: Exception) {
                    failed++
                    Json.write(Obj(mapOf("errors" to Lst(listOf(Str("${job["file"]}: ${e.message ?: e}"))))))!!
                }
            File(job["out"].toString()).writeText(text)
        }
        return if (failed == 0) 0 else 1
    }
    val file = args.firstOrNull { !it.startsWith("--") } ?: return 2
    val theme = opt("--theme")?.let { toml(File(it).readText()) }.orEmpty()
    val data = opt("--data")?.let { File(it) }?.takeIf { it.exists() }?.let { Json.parse(it.readText()) as? Obj }?.fields.orEmpty()
    val variants = (Json.parse(File(opt("--variants") ?: return 2).readText()) as Lst).items.map { it as Obj }
    println(trees(File(file).readText(), theme, data, variants, "--live" in args))
    return 0
}

private fun trees(
    source: String,
    theme: Map<String, Int>,
    data: Map<String, Value>,
    variants: List<Obj>,
    live: Boolean,
): String {
    val program = Compiler.compile(source)
    val host = PreviewHost(program, theme, data, live)
    val out = LinkedHashMap<String, Value>()
    for (v in variants) {
        val f = v.fields
        val id = f["id"].toString()
        host.setTile(f["cols"]?.num(), f["rows"]?.num(), f["w"]?.num(), f["h"]?.num())
        val canvases = (f["canvas"] as? Obj)?.fields.orEmpty().mapValues { (_, s) -> (s as Lst).items.let { it[0].num()!! to it[1].num()!! } }
        out[id] = TreeWalk(host, canvases).tree(false)
        val screen = f["screen"] as? Lst
        if (screen != null && program.screen != null) {
            host.setScreen(screen.items[0].num(), screen.items[1].num())
            out["$id#screen"] = TreeWalk(host, canvases).tree(true)
        }
    }
    out["meta"] =
        Obj(
            mapOf(
                "name" to Str(program.name),
                "minSize" to Lst(listOf(Num(program.minSize.first.toDouble()), Num(program.minSize.second.toDouble()))),
                "size" to (program.size?.let { Lst(listOf(Num(it.first.toDouble()), Num(it.second.toDouble()))) } ?: Null),
                "screen" to bool(program.screen != null),
                "terminal" to bool(program.terminal),
            ),
        )
    out["errors"] = Lst(host.errors.map(::Str))
    return Json.write(Obj(out))!!
}

private fun Value.num(): Double? = (this as? Num)?.v ?: toString().toDoubleOrNull()

/** colors.toml's `name = "#rrggbb"` lines. */
private fun toml(text: String): Map<String, Int> =
    text.lines().mapNotNull { line ->
        val m = Regex("""^\s*([\w-]+)\s*=\s*"#([0-9a-fA-F]{6})"""").find(line) ?: return@mapNotNull null
        m.groupValues[1] to (0xFF000000.toInt() or m.groupValues[2].toInt(16))
    }.toMap()

/** WidgetInstance's Host, for a preview: values from the data file, no coroutines, no Android. */
private class PreviewHost(
    val program: Program,
    private val colors: Map<String, Int>,
    private val data: Map<String, Value>,
    private val live: Boolean,
) : Host {
    override val budget = Budget()
    val root = Env.root(this)
    val errors = LinkedHashSet<String>()
    private val slots = arrayOfNulls<Value>(program.globals.size)
    private val lets = HashMap<Int, Value>()
    private var tile = listOf<Double?>(null, null, null, null)
    private var screen = listOf<Double?>(null, null)
    private val last = HashMap<Int, Value>()

    init {
        program.globals.forEachIndexed { i, g ->
            slots[i] =
                when (g) {
                    is Global.Sampled -> if (g.prev) Null else Lst(emptyList())
                    is Global.Asset -> Str("asset:${g.name}")
                    else -> Null
                }
        }
        program.globals.forEachIndexed { i, g -> if (g is Global.State) write(i, data[g.name] ?: eval(g.init, root, g.name)) }
        // The sources, one update round per value of the longest sequence; history()/prev() sample after each.
        val sources = program.globals.withIndex().filter { it.value is Global.Source }
        val seqs = sources.associate { (i, g) -> i to values(g as Global.Source) }
        val rounds = maxOf(2, seqs.values.maxOfOrNull { it.size } ?: 0)
        for (r in 0 until rounds) {
            for ((i, vs) in seqs) if (vs.isNotEmpty()) write(i, vs[minOf(r, vs.size - 1)])
            sample()
        }
    }

    /** A source's values: the data file's (a "seq" is several), else what it would be with no device behind it. */
    private fun values(g: Global.Source): List<Value> {
        val given = data[g.name]
        val raw =
            when {
                given is Obj && given.fields["seq"] is Lst -> (given.fields["seq"] as Lst).items
                given != null -> listOf(given)
                g.kind == "clock" -> listOf(Num(Math.floor(System.currentTimeMillis() / 1000.0)))
                g.kind == "http" && live -> listOfNotNull(fetch(g))
                else -> emptyList()
            }
        return raw.map { v ->
            val parsed = if (v is Str && g.json) Json.parseOrText(v.v) else v
            if (g.status && !(parsed is Obj && "ok" in parsed.fields)) Obj(mapOf("out" to parsed, "err" to Str(""), "code" to Num(0.0), "ok" to bool(true))) else parsed
        }
    }

    private fun fetch(g: Global.Source): Value? =
        try {
            val url = eval(g.arg!!, root, g.name).toString()
            val req = HttpRequest.newBuilder(URI(url)).timeout(Duration.ofSeconds(g.timeout.toLong().coerceAtLeast(5))).header("User-Agent", "curl/8.0").GET().build()
            val res = HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NORMAL).build().send(req, HttpResponse.BodyHandlers.ofString())
            Str(res.body())
        } catch (e: Exception) {
            report("${g.name}: ${e.message}")
            null
        }

    private fun sample() {
        lets.clear()
        program.globals.forEachIndexed { i, g ->
            if (g !is Global.Sampled) return@forEachIndexed
            val v = eval(g.of, root, g.name)
            if (v == Null) return@forEachIndexed
            if (g.prev) {
                val before = last[i]
                if (before != v) {
                    write(i, before ?: Null)
                    last[i] = v
                }
            } else {
                write(i, Lst((((slots[i] as? Lst)?.items).orEmpty() + v).takeLast(g.keep)))
            }
        }
    }

    override fun read(slot: Int): Value {
        val g = program.globals[slot]
        if (g is Global.Let) return lets[slot] ?: eval(g.value, root, g.name).also { lets[slot] = it }
        return slots[slot] ?: Null
    }

    override fun write(
        slot: Int,
        value: Value,
    ) {
        slots[slot] = value
        lets.clear()
    }

    /** As ThemePalette: the launcher's names over a theme's colors.toml, then the theme's own names. */
    override fun theme(name: String): Int? =
        when (name) {
            "surface" -> colors["lighter_background"]
            "muted" -> colors["dark_foreground"]
            "border" -> colors["muted"]
            "white" -> 0xFFFFFFFF.toInt()
            "black" -> 0xFF000000.toInt()
            else -> colors[name]
        }

    override fun time() = 0.0

    override fun tile(name: String): Value {
        val v =
            when (name) {
                "linux" -> return data["linux"] ?: bool(true)
                "corners" -> return Num(1.0)
                "screenWidth" -> screen[0]
                "screenHeight" -> screen[1]
                "cols" -> tile[0]
                "rows" -> tile[1]
                "tileWidth" -> tile[2]
                "tileHeight" -> tile[3]
                else -> null
            }
        return v?.let { Num(Math.round(it).toDouble()) } ?: Null
    }

    fun setTile(
        cols: Double?,
        rows: Double?,
        w: Double?,
        h: Double?,
    ) {
        tile = listOf(cols, rows, w, h)
        lets.clear()
    }

    fun setScreen(
        w: Double?,
        h: Double?,
    ) {
        screen = listOf(w, h)
        lets.clear()
    }

    override fun act(
        name: String,
        args: List<Value>,
    ) {}

    override fun report(message: String) {
        if (errors.size < 50) errors += "${program.name}: $message"
    }

    fun eval(
        ev: dev.omalauncher.widgets.lang.Ev,
        env: Env,
        where: String,
    ): Value {
        ev.const?.let { return it }
        return try {
            budget.run { ev(env) }
        } catch (e: WidgetError) {
            report("$where: ${e.message}")
            Null
        } catch (e: RuntimeException) {
            report("$where: $e")
            Null
        } catch (e: StackOverflowError) {
            report("$where: too deeply nested")
            Null
        }
    }
}

/** WidgetTree.kt's walk (app module), as Values: { k, id, p, h, c } and a Canvas's ops. Keep in step with it. */
private class TreeWalk(
    private val inst: PreviewHost,
    private val canvasSizes: Map<String, Pair<Double, Double>>,
) {
    fun tree(screen: Boolean): Value {
        val program = inst.program
        val nodes = if (screen) program.screen.orEmpty() else program.root
        return Obj(
            linkedMapOf(
                "k" to Str("Root"),
                "id" to Str(if (screen) "s" else "r"),
                "padding" to Num(program.padding),
                "tap" to bool(!screen && program.onTap != null),
                "background" to (program.background?.let { css(inst.eval(it, inst.root, "background")) } ?: Null),
                "c" to nodes(nodes, inst.root, if (screen) "s" else "r"),
            ),
        )
    }

    private fun nodes(
        list: List<WNode>,
        env: Env,
        path: String,
    ): Lst {
        val out = ArrayList<Value>()
        list.forEachIndexed { i, n -> node(n, env, "$path.$i", out) }
        return Lst(out)
    }

    private fun items(v: Value): List<Value> =
        when (v) {
            is Lst -> v.items
            is Obj -> v.fields.map { (k, x) -> Obj(mapOf("key" to Str(k), "value" to x)) }
            else -> emptyList()
        }.let { if (it.size > Builtins.MAX_LIST) it.subList(0, Builtins.MAX_LIST) else it }

    private fun node(
        node: WNode,
        env: Env,
        id: String,
        out: MutableList<Value>,
    ) {
        when (node) {
            is WNode.Element -> element(node, env, id)?.let(out::add)
            is WNode.If -> {
                val branch = if (inst.eval(node.cond, env, "if").truthy) node.then else node.orElse
                branch.forEachIndexed { i, n -> node(n, env, "$id.${if (branch === node.then) "t" else "e"}$i", out) }
            }
            is WNode.For ->
                items(inst.eval(node.list, env, "for")).forEachIndexed { i, v ->
                    val child = env.child(v, Num(i.toDouble()))
                    val key = node.key?.let { inst.eval(it, child, "for key").toString() } ?: i.toString()
                    node.body.forEachIndexed { j, n -> node(n, child, "$id[$key].$j", out) }
                }
            is WNode.Lets -> {
                val frame = env.lets(node.values)
                node.children.forEachIndexed { i, n -> node(n, frame, "$id.$i", out) }
            }
            is WNode.Use -> {
                val inner = Env(inst, inst.root, Array(node.args.size) { i -> { inst.eval(node.args[i], env, "${node.component} parameter") } })
                if (node.wrapper.isEmpty()) {
                    node.body.forEachIndexed { i, n -> node(n, inner, "$id.$i", out) }
                } else {
                    val wrapper = WNode.Element("Box", node.wrapper, emptyMap(), emptyMap(), emptyList(), node.pos)
                    element(wrapper, env, id)?.let { box -> out += Obj(box.fields + ("c" to nodes(node.body, inner, id))) }
                }
            }
            is WNode.Draw -> {}
        }
    }

    private fun element(
        el: WNode.Element,
        env: Env,
        id: String,
    ): Obj? {
        val props = LinkedHashMap<String, Value>()
        for ((name, ev) in el.props) {
            val v = inst.eval(ev, env, "${el.kind}.$name")
            props[name] = if (name in COLORS) css(v) ?: Null else json(v)
        }
        props["visible"]?.let { if (!it.truthy) return null }
        val o = linkedMapOf<String, Value>("k" to Str(el.kind), "id" to Str(id), "p" to Obj(props))
        if (el.handlers.isNotEmpty()) o["h"] = Lst(el.handlers.keys.map(::Str))
        if (el.kind == "Canvas") {
            val (w, h) = canvasSizes[id] ?: (100.0 to 100.0)
            val ops = ArrayList<Value>()
            try {
                draw(el.children, env.child(Num(w), Num(h)), ops)
            } catch (e: WidgetError) {
                inst.report("Canvas: ${e.message}")
            }
            o["ops"] = Lst(ops)
        } else if (el.children.isNotEmpty()) {
            o["c"] = nodes(el.children, env, id)
        }
        return Obj(o)
    }

    private fun draw(
        list: List<WNode>,
        env: Env,
        out: MutableList<Value>,
    ) {
        for (n in list) {
            when (n) {
                is WNode.Draw -> {
                    if (out.size > MAX_OPS) throw WidgetError("more than $MAX_OPS drawing calls in one frame")
                    val values = n.op == "path" || n.op == "text" || n.op == "image" || n.op == "sprite"
                    val args =
                        n.args.mapIndexed { i, a ->
                            val v = inst.eval(a, env, "Canvas.${n.op}")
                            if (i == 0 && values) json(v) else Num((v as? Num)?.v?.takeIf { it.isFinite() } ?: 0.0)
                        }
                    val named = LinkedHashMap<String, Value>()
                    for ((name, ev) in n.named) {
                        val v = inst.eval(ev, env, "Canvas.${n.op} $name")
                        named[name] = if (name in DRAW_COLORS) paint(v) ?: Null else json(v)
                    }
                    val op = linkedMapOf<String, Value>("op" to Str(n.op), "a" to Lst(args), "n" to Obj(named))
                    n.children?.let { kids ->
                        val nested = ArrayList<Value>()
                        draw(kids, env, nested)
                        op["c"] = Lst(nested)
                    }
                    out += Obj(op)
                }
                is WNode.If -> draw(if (inst.eval(n.cond, env, "if").truthy) n.then else n.orElse, env, out)
                is WNode.For -> items(inst.eval(n.list, env, "for")).forEachIndexed { i, v -> draw(n.body, env.child(v, Num(i.toDouble())), out) }
                is WNode.Lets -> draw(n.children, env.lets(n.values), out)
                else -> {}
            }
        }
    }

    private fun css(v: Value): Value? = Builtins.argb(v, inst)?.let { Str(cssColor(it)) }

    private fun paint(v: Value): Value? =
        when (v) {
            is Gradient ->
                Obj(
                    mapOf(
                        "gradient" to Str(if (v.radial) "radial" else "linear"),
                        "coords" to Lst(v.coords.map { Num(it.toDouble()) }),
                        "colors" to Lst(v.colors.map { css(it) ?: Null }),
                    ),
                )
            else -> css(v)
        }

    private fun json(v: Value): Value =
        when (v) {
            is Null, is Str, is Bool -> v
            is Num -> if (v.v.isFinite()) v else Null
            is Lst -> Lst(v.items.map(::json))
            is Obj -> Obj(v.fields.mapValues { json(it.value) })
            is Col -> css(v) ?: Null
            is Gradient -> paint(v) ?: Null
            else -> Str(v.toString())
        }

    companion object {
        private val COLORS = setOf("color", "background", "borderColor", "track", "tint", "fallback")
        private val DRAW_COLORS = setOf("fill", "stroke", "color")
        private const val MAX_OPS = 20_000

        fun cssColor(argb: Int): String {
            val a = (argb ushr 24) and 0xff
            return "rgba(${(argb shr 16) and 0xff},${(argb shr 8) and 0xff},${argb and 0xff},${"%.3f".format(java.util.Locale.ROOT, a / 255.0)})"
        }
    }
}
