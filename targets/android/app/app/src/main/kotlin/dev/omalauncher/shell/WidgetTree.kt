package dev.omalauncher.shell

import dev.omalauncher.widgets.lang.Action
import dev.omalauncher.widgets.lang.Bool
import dev.omalauncher.widgets.lang.Builtins
import dev.omalauncher.widgets.lang.Col
import dev.omalauncher.widgets.lang.Env
import dev.omalauncher.widgets.lang.Gradient
import dev.omalauncher.widgets.lang.Lst
import dev.omalauncher.widgets.lang.Null
import dev.omalauncher.widgets.lang.Num
import dev.omalauncher.widgets.lang.Obj
import dev.omalauncher.widgets.lang.Str
import dev.omalauncher.widgets.lang.Value
import dev.omalauncher.widgets.lang.WNode
import dev.omalauncher.widgets.lang.WidgetError
import dev.omalauncher.widgets.render.items
import dev.omalauncher.widgets.runtime.WidgetInstance
import org.json.JSONArray
import org.json.JSONObject

/**
 * A widget's node tree as the web shell renders it (shell/ui/owl.js): the same walk as Render.kt (if, for, let,
 * components), each element's properties evaluated to plain JSON - colors resolved to CSS, a Canvas's drawing calls
 * flattened to an op list - and its handlers registered under the element's id, so the page can fire them.
 *
 * Read inside snapshotFlow: every value it reads is tracked, so the widget's tree is sent again whenever its state
 * changes, and only then.
 *
 * Node shape: { k: kind, id, p: { props }, h: [handler names], c: [children] }; Canvas adds ops:
 * [{ op, a: [args], n: { named }, c: [nested ops] }].
 */
class WidgetTree(
    private val inst: WidgetInstance,
    /** A Canvas's size in dp by its id, as the page measured it; Canvas code draws to its own size. */
    private val canvasSizes: Map<String, Pair<Double, Double>>,
) {
    /** The handlers of the last tree, by "<element id>/<handler name>". */
    val handlers = HashMap<String, Pair<Action, Env>>()

    fun tree(screen: Boolean = false): JSONObject {
        handlers.clear()
        val program = inst.program
        val nodes = if (screen) program.screen.orEmpty() else program.root
        val root =
            JSONObject()
                .put("k", "Root")
                .put("id", if (screen) "s" else "r")
                .put("padding", program.padding)
                .putOpt("background", program.background?.let { css(inst.eval(it, inst.root, "background")) })
                .put("c", nodes(nodes, inst.root, if (screen) "s" else "r"))
        return root
    }

    private fun nodes(
        list: List<WNode>,
        env: Env,
        path: String,
    ): JSONArray {
        val out = JSONArray()
        list.forEachIndexed { i, n -> node(n, env, "$path.$i", out) }
        return out
    }

    /** [node] into [out]: an element becomes one entry; if/for/let/components put their children in its place. */
    private fun node(
        node: WNode,
        env: Env,
        id: String,
        out: JSONArray,
    ) {
        when (node) {
            is WNode.Element -> element(node, env, id)?.let(out::put)
            is WNode.If -> {
                val branch = if (inst.eval(node.cond, env, "if").truthy) node.then else node.orElse
                branch.forEachIndexed { i, n -> node(n, env, "$id.${if (branch === node.then) "t" else "e"}$i", out) }
            }
            is WNode.For ->
                items(inst.eval(node.list, env, "for")).forEachIndexed { i, v ->
                    val child = env.child(v, Num(i.toDouble()))
                    // Keyed rows keep their ids as they move, so the page keeps their state (scroll, focus).
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
                    element(wrapper, env, id)?.let { box ->
                        box.put("c", nodes(node.body, inner, id))
                        out.put(box)
                    }
                }
            }
            is WNode.Draw -> {} // only inside a Canvas
        }
    }

    private fun element(
        el: WNode.Element,
        env: Env,
        id: String,
    ): JSONObject? {
        val props = JSONObject()
        for ((name, ev) in el.props) {
            val v = inst.eval(ev, env, "${el.kind}.$name")
            props.put(name, if (name in COLORS) css(v) ?: JSONObject.NULL else json(v))
        }
        if (props.has("visible") && !truthy(props.opt("visible"))) return null
        val o = JSONObject().put("k", el.kind).put("id", id).put("p", props)
        if (el.handlers.isNotEmpty()) {
            o.put("h", JSONArray(el.handlers.keys))
            for ((name, action) in el.handlers) handlers["$id/$name"] = action to env
        }
        when (el.kind) {
            "Canvas" -> {
                val (w, h) = canvasSizes[id] ?: (100.0 to 100.0)
                val ops = JSONArray()
                try {
                    draw(el.children, env.child(Num(w), Num(h)), ops)
                } catch (e: WidgetError) {
                    inst.report("Canvas: ${e.message}")
                }
                o.put("ops", ops)
            }
            else -> if (el.children.isNotEmpty()) o.put("c", nodes(el.children, env, id))
        }
        return o
    }

    /** A Canvas's drawing calls, as Canvas.kt's Painter walks them, into plain ops for a 2D canvas. */
    private fun draw(
        list: List<WNode>,
        env: Env,
        out: JSONArray,
    ) {
        for (n in list) {
            when (n) {
                is WNode.Draw -> {
                    if (out.length() > MAX_OPS) throw WidgetError("more than $MAX_OPS drawing calls in one frame")
                    val values = n.op == "path" || n.op == "text" || n.op == "image" || n.op == "sprite"
                    val args = JSONArray()
                    n.args.forEachIndexed { i, a ->
                        val v = inst.eval(a, env, "Canvas.${n.op}")
                        args.put(if (i == 0 && values) json(v) else (v as? Num)?.v?.takeIf { it.isFinite() } ?: v.num0())
                    }
                    val named = JSONObject()
                    for ((name, ev) in n.named) {
                        val v = inst.eval(ev, env, "Canvas.${n.op} $name")
                        named.put(name, if (name in DRAW_COLORS) paint(v) ?: JSONObject.NULL else json(v))
                    }
                    val op = JSONObject().put("op", n.op).put("a", args).put("n", named)
                    n.children?.let { kids ->
                        val nested = JSONArray()
                        draw(kids, env, nested)
                        op.put("c", nested)
                    }
                    out.put(op)
                }
                is WNode.If -> draw(if (inst.eval(n.cond, env, "if").truthy) n.then else n.orElse, env, out)
                is WNode.For -> items(inst.eval(n.list, env, "for")).forEachIndexed { i, v -> draw(n.body, env.child(v, Num(i.toDouble())), out) }
                is WNode.Lets -> draw(n.children, env.lets(n.values), out)
                else -> {}
            }
        }
    }

    /** Runs the handler [name] of element [id] with the event's numbers (x, y, dx, dy in dp). */
    fun fire(
        id: String,
        name: String,
        args: List<Double>,
    ) {
        val (action, env) = handlers["$id/$name"] ?: return
        try {
            action.run(env, args.map(::Num))
        } catch (e: WidgetError) {
            inst.report("$name: ${e.message}")
        } catch (e: RuntimeException) {
            inst.report("$name: $e")
        }
    }

    private fun Value.num0(): Double = (this as? Num)?.v?.takeIf { it.isFinite() } ?: 0.0

    private fun truthy(v: Any?) = v != null && v != JSONObject.NULL && v != false && v != 0 && v != 0.0 && v != ""

    /** A color value as CSS, resolved now: a theme name follows the current theme. */
    private fun css(v: Value): String? = Builtins.argb(v, inst)?.let(::cssColor)

    /** A fill or stroke: a color, or a gradient. */
    private fun paint(v: Value): Any? =
        when (v) {
            is Gradient ->
                JSONObject()
                    .put("gradient", if (v.radial) "radial" else "linear")
                    .put("coords", JSONArray(v.coords.map { it.toDouble() }))
                    .put("colors", JSONArray(v.colors.map { css(it) }))
            else -> css(v)
        }

    private fun json(v: Value): Any =
        when (v) {
            is Null -> JSONObject.NULL
            is Num -> v.v.takeIf { it.isFinite() } ?: JSONObject.NULL
            is Str -> v.v
            is Bool -> v.v
            is Lst -> JSONArray(v.items.map(::json))
            is Obj -> JSONObject().apply { for ((k, x) in v.fields) put(k, json(x)) }
            is Col -> css(v) ?: JSONObject.NULL
            is Gradient -> paint(v) ?: JSONObject.NULL
            else -> v.toString()
        }

    companion object {
        /** Element properties that are colors. */
        private val COLORS = setOf("color", "background", "borderColor", "track", "tint", "fallback")

        /** Drawing-call arguments that are paints (a color or a gradient). */
        private val DRAW_COLORS = setOf("fill", "stroke", "color")

        private const val MAX_OPS = 20_000

        fun cssColor(argb: Int): String {
            val a = (argb ushr 24) and 0xff
            return "rgba(${(argb shr 16) and 0xff},${(argb shr 8) and 0xff},${argb and 0xff},${"%.3f".format(java.util.Locale.ROOT, a / 255.0)})"
        }
    }
}
