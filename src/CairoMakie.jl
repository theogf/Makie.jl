module CairoMakie

using AbstractPlotting, LinearAlgebra
using Colors, GeometryBasics, FileIO, StaticArrays
import Cairo

using AbstractPlotting: Scene, Lines, Text, Image, Heatmap, Scatter, @key_str, broadcast_foreach
using AbstractPlotting: convert_attribute, @extractvalue, LineSegments, to_ndim, NativeFont
using AbstractPlotting: @info, @get_attribute, Combined
using AbstractPlotting: to_value, to_colormap, extrema_nan
using Cairo: CairoContext, CairoARGBSurface, CairoSVGSurface, CairoPDFSurface

const LIB_CAIRO = if isdefined(Cairo, :libcairo)
    Cairo.libcairo
else
    Cairo._jl_libcairo
end

include("infrastructure.jl")
include("utils.jl")
include("fonts.jl")
include("primitives.jl")

function draw_atomic(scene::Scene, screen::CairoScreen, primitive::AbstractPlotting.Mesh)
    @get_attribute(primitive, (color,))

    colormap = get(primitive, :colormap, nothing) |> to_value |> to_colormap
    colorrange = get(primitive, :colorrange, nothing) |> to_value

    ctx = screen.context
    model = primitive.model[]
    mesh = primitive[1][]
    vs = coordinates(mesh); fs = faces(mesh)
    uv = hasproperty(mesh, :uv) ? mesh.uv : nothing
    pattern = Cairo.CairoPatternMesh()

    cols = per_face_colors(color, colormap, colorrange, vs, fs, uv)
    for (f, (c1, c2, c3)) in zip(fs, cols)
        t1, t2, t3 =  project_position.(scene, vs[f], (model,)) #triangle points
        Cairo.mesh_pattern_begin_patch(pattern)

        Cairo.mesh_pattern_move_to(pattern, t1...)
        Cairo.mesh_pattern_line_to(pattern, t2...)
        Cairo.mesh_pattern_line_to(pattern, t3...)

        mesh_pattern_set_corner_color(pattern, 0, c1)
        mesh_pattern_set_corner_color(pattern, 1, c2)
        mesh_pattern_set_corner_color(pattern, 2, c3)

        Cairo.mesh_pattern_end_patch(pattern)
    end
    Cairo.set_source(ctx, pattern)
    Cairo.close_path(ctx)
    Cairo.paint(ctx)
    return nothing
end


function draw_atomic(scene::Scene, screen::CairoScreen, primitive::Union{Heatmap, Image})
    draw_image(scene, screen, primitive)
end

function draw_image(scene, screen, attributes)
    ctx = screen.context
    image = attributes[3][]
    x, y = attributes[1][], attributes[2][]
    model = attributes[:model][]
    imsize = (extrema_nan(x), extrema_nan(y))
    xy_ = project_position(scene, Point2f0(first.(imsize)), model)
    xymax_ = project_position(scene, Point2f0(last.(imsize)), model)
    xy = min.(xy_, xymax_)
    xymax = max.(xy_, xymax_)
    w, h = xymax .- xy
    interp = to_value(get(attributes, :interpolate, true))
    interp = interp ? Cairo.FILTER_BEST : Cairo.FILTER_NEAREST
    s = to_cairo_image(image, attributes)
    Cairo.rectangle(ctx, xy..., w, h)
    Cairo.save(ctx)
    Cairo.translate(ctx, xy[1], xy[2])
    Cairo.scale(ctx, w / s.width, h / s.height)
    Cairo.set_source_surface(ctx, s, 0, 0)
    p = Cairo.get_source(ctx)
    # Set filter doesn't work!?
    Cairo.pattern_set_filter(p, interp)
    Cairo.fill(ctx)
    Cairo.restore(ctx)
end

function draw_marker(ctx, marker, pos, scale, strokecolor, strokewidth)
    pos += Point2f0(scale[1] / 2, -scale[2] / 2)
    Cairo.arc(ctx, pos[1], pos[2], scale[1] / 2, 0, 2*pi)
    Cairo.fill(ctx)
    sc = to_color(strokecolor)
    if strokewidth > 0.0
        Cairo.set_source_rgba(ctx, red(sc), green(sc), blue(sc), alpha(sc))
        Cairo.set_line_width(ctx, Float64(strokewidth))
        Cairo.stroke(ctx)
    end
end

function draw_marker(ctx, marker::Char, font, pos, scale, strokecolor, strokewidth)

    cairoface = set_ft_font(ctx, font)

    charextent = AbstractPlotting.FreeTypeAbstraction.internal_get_extent(font, marker)
    inkbb = AbstractPlotting.FreeTypeAbstraction.inkboundingbox(charextent)

    # scale normalized bbox by font size
    inkbb_scaled = FRect2D(origin(inkbb) .* scale, widths(inkbb) .* scale)

    # flip y for the centering shift of the character because in Cairo y goes down
    centering_offset = [1, -1] .* (-origin(inkbb_scaled) .- 0.5 .* widths(inkbb_scaled))
    # this is the origin where we actually have to place the glyph so it's centered
    charorigin = pos .+ centering_offset

    Cairo.move_to(ctx, charorigin...)
    mat = scale_matrix(scale...)
    set_font_matrix(ctx, mat)
    Cairo.text_path(ctx, string(marker))
    Cairo.fill_preserve(ctx)
    Cairo.set_line_width(ctx, strokewidth)
    Cairo.set_source_rgba(ctx, rgbatuple(strokecolor)...)
    Cairo.stroke(ctx)

    # if we use set_ft_font we should destroy the pointer it returns
    cairo_font_face_destroy(cairoface)

end


function draw_marker(ctx, marker::Union{Rect, Type{<: Rect}}, pos, scale, strokecolor, strokewidth)
    s2 = Point2f0(scale[1], -scale[2])
    Cairo.rectangle(ctx, pos..., s2...)
    Cairo.fill(ctx);
    if strokewidth > 0.0
        sc = to_color(strokecolor)
        Cairo.set_source_rgba(ctx, red(sc), green(sc), blue(sc), alpha(sc))
        Cairo.set_line_width(ctx, Float64(strokewidth))
        Cairo.stroke(ctx)
    end
end

function draw_atomic(scene::Scene, screen::CairoScreen, primitive::Scatter)
    fields = @get_attribute(primitive, (color, markersize, strokecolor, strokewidth, marker, marker_offset))
    @get_attribute(primitive, (transform_marker,))

    cmap = get(primitive, :colormap, nothing) |> to_value |> to_colormap
    crange = get(primitive, :colorrange, nothing) |> to_value
    ctx = screen.context
    model = primitive[:model][]
    positions = primitive[1][]
    isempty(positions) && return
    size_model = transform_marker ? model : Mat4f0(I)

    font = AbstractPlotting.defaultfont()

    broadcast_foreach(primitive[1][], fields...) do point, c, markersize, strokecolor, strokewidth, marker, mo

        # if we give size in pixels, the size is always equal to that value
        scale = if markersize isa AbstractPlotting.Pixel
            [markersize.value, markersize.value]
        else
            # otherwise calculate a scaled size
            project_scale(scene, markersize, size_model)
        end
        pos = project_position(scene, point, model)

        Cairo.set_source_rgba(ctx, extract_color(cmap, crange, c)...)
        m = convert_attribute(marker, key"marker"(), key"scatter"())
        if m isa Char
            draw_marker(ctx, m, font, pos, scale, strokecolor, strokewidth)
        else
            draw_marker(ctx, m, pos, scale, strokecolor, strokewidth)
        end
    end
    nothing
end

function draw_atomic(scene::Scene, screen::CairoScreen, primitive::Text)
    ctx = screen.context
    @get_attribute(primitive, (textsize, color, font, align, rotation, model, justification, lineheight))
    txt = to_value(primitive[1])
    position = primitive.attributes[:position][]
    N = length(txt)
    atlas = AbstractPlotting.get_texture_atlas()
    if position isa StaticArrays.StaticArray # one position to place text
        position = AbstractPlotting.layout_text(
            txt, position, textsize,
            font, align, rotation, model, justification, lineheight
        )
    end
    stridx = 1
    broadcast_foreach(1:N, position, textsize, color, font, rotation) do i, p, ts, cc, f, r
        Cairo.save(ctx)
        char = txt[stridx]

        stridx = nextind(txt, stridx)
        pos = project_position(scene, p, model)
        scale = project_scale(scene, ts, model)
        Cairo.move_to(ctx, pos[1], pos[2])
        Cairo.set_source_rgba(ctx, red(cc), green(cc), blue(cc), alpha(cc))
        cairoface = set_ft_font(ctx, f)

        mat = scale_matrix(scale...)
        set_font_matrix(ctx, mat)

        # TODO this only works in 2d
        Cairo.rotate(ctx, -AbstractPlotting.quaternion_to_2d_angle(r))

        if !(char in ('\r', '\n'))
            Cairo.show_text(ctx, string(char))
        end

        cairo_font_face_destroy(cairoface)

        Cairo.restore(ctx)
    end
    nothing
end

function rgbatuple(c::Colorant)
    rgba = RGBA(c)
    red(rgba), green(rgba), blue(rgba), alpha(rgba)
end

"""
Special method for polys so we don't fall back to atomic meshes, which are much more
complex and slower to draw than standard paths with single color.
"""
function draw_plot(scene::Scene, screen::CairoScreen, poly::Poly)
    # dispatch on input arguments to poly to use smarter drawing methods than
    # meshes if possible
    draw_poly(scene, screen, poly, to_value.(poly.input_args)...)
end

"""
Fallback method for args without special treatment.
"""
function draw_poly(scene::Scene, screen::CairoScreen, poly, args...)
    draw_poly_as_mesh(scene, screen, poly)
end

function draw_poly_as_mesh(scene, screen, poly)
    draw_plot(scene, screen, poly.plots[1])
    draw_plot(scene, screen, poly.plots[2])
end

function draw_poly(scene::Scene, screen::CairoScreen, poly, points::Vector{<:Point2})

    # in the rare case of per-vertex colors redirect to mesh drawing
    if poly.color[] isa Array
        draw_poly_as_mesh(scene, screen, poly)
        return
    end

    model = poly.model[]
    points = project_position.(Ref(scene), points, Ref(model))
    Cairo.move_to(screen.context, points[1]...)
    for p in points[2:end]
        Cairo.line_to(screen.context, p...)
    end
    Cairo.close_path(screen.context)
    Cairo.set_source_rgba(screen.context, rgbatuple(to_color(poly.color[]))...)
    Cairo.fill_preserve(screen.context)
    Cairo.set_source_rgba(screen.context, rgbatuple(to_color(poly.strokecolor[]))...)
    Cairo.set_line_width(screen.context, poly.strokewidth[])
    Cairo.stroke(screen.context)
end

function project_rect(scene, rect::Rect, model)
    mini = project_position(scene, minimum(rect), model)
    maxi = project_position(scene, maximum(rect), model)
    Rect(mini, maxi .- mini)
end

function draw_poly(scene::Scene, screen::CairoScreen, poly, rects::Vector{<:Rect2D})
    model = poly.model[]
    projected_rects = project_rect.(Ref(scene), rects, Ref(model))

    color = poly.color[]
    if color isa AbstractArray{<:Number}
        color = numbers_to_colors(color, poly)
    end
    strokecolor = poly.strokecolor[]
    if strokecolor isa AbstractArray{<:Number}
        strokecolor = numbers_to_colors(strokecolor, poly)
    end

    broadcast_foreach(projected_rects, color, strokecolor, poly.strokewidth[]) do r, c, sc, sw
        Cairo.rectangle(screen.context, origin(r)..., widths(r)...)
        Cairo.set_source_rgba(screen.context, rgbatuple(to_color(c))...)
        Cairo.fill_preserve(screen.context)
        Cairo.set_source_rgba(screen.context, rgbatuple(to_color(sc))...)
        Cairo.set_line_width(screen.context, sw)
        Cairo.stroke(screen.context)
    end
end

function draw_poly(scene::Scene, screen::CairoScreen, poly, rect::Rect2D)
    draw_poly(scene, screen, poly, [rect])
end

function __init__()
    activate!()
    AbstractPlotting.register_backend!(AbstractPlotting.current_backend[])
end

function display_path(type::String)
    if !(type in ("svg", "png", "pdf", "eps"))
        error("Only \"svg\", \"png\", \"eps\" and \"pdf\" are allowed for `type`. Found: $(type)")
    end
    return joinpath(@__DIR__, "display." * type)
end

function activate!(; inline = true, type = "svg")
    AbstractPlotting.current_backend[] = CairoBackend(display_path(type))
    AbstractPlotting.use_display[] = !inline
    return
end

end
