extends Node3D

@onready var camera = get_node("Camera")
@onready var screen_texture = get_node("TextureRect")

@export_file var splat_filename: String = "garden.ply"
@export var render_texture_size: Vector2i = Vector2i(1152, 648)

const NUM_PROPERTIES = 62
const PROJECTED_SPLAT_FLOATS = 11
const PREPROCESS_WORKGROUP_SIZE = 512
const SORT_WORKGROUP_SIZE = 512
const SORT_BLOCKS_PER_WORKGROUP = 16
const RADIX_SORT_BINS = 256
const SORT_PASSES = 2 

var rd = RenderingServer.get_rendering_device()
var pipeline: RID
var shader: RID
var vertex_format: int
var blend := RDPipelineColorBlendState.new()

var framebuffer: RID
var vertex_array: RID
var dynamic_uniform_set_A: RID
var dynamic_uniform_set_B: RID
var current_dynamic_uniform_set: RID
var clear_color_values := PackedColorArray([Color(0, 0, 0, 0)])

var preprocess_pipeline: RID
var histogram_pipeline: RID
var sort_pipeline: RID
var preprocess_shader: RID
var radixsort_hist_shader: RID
var radixsort_shader: RID

var preprocess_uniform_set0: RID
var preprocess_uniform_set1: RID
var hist_uniform_set_A: RID
var hist_uniform_set_B: RID
var sort_uniform_set_A: RID
var sort_uniform_set_B: RID

var output_tex: RID
var display_texture: Texture2DRD

var params_buffer: RID
var camera_matrices_buffer: RID
var projected_splats_buffer: RID
var visible_counter_buffer: RID
var sort_key_buffer: RID
var sort_key_temp_buffer: RID
var histogram_buffer: RID

var num_vertex: int = 0
var visible_count: int = 0
var max_sort_workgroups: int = 1

var num_coeffs: int = 45
var num_coeffs_per_color: int = num_coeffs / 3
var sh_degree = sqrt(num_coeffs_per_color + 1) - 1
var active_sh_degree: float = sh_degree
var modifier: float = 1.0
var last_direction := Vector3.ZERO
var last_position := Vector3.ZERO

var vertices: PackedFloat32Array


func _matrix_to_bytes(t: Transform3D) -> PackedByteArray:
	var _basis: Basis = t.basis
	var origin: Vector3 = t.origin
	return PackedFloat32Array([
		_basis.x.x,_basis.x.y,_basis.x.z, 0.0,
		_basis.y.x,_basis.y.y,_basis.y.z, 0.0,
		_basis.z.x,_basis.z.y,_basis.z.z, 0.0,
		origin.x, origin.y, origin.z, 1.0,
	]).to_byte_array()


func _make_storage_uniform(binding: int, buffer: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform


func _initialise_screen_texture():
	display_texture = Texture2DRD.new()
	screen_texture.texture = display_texture


func _build_camera_buffer_bytes() -> PackedByteArray:
	var camera_bytes := PackedByteArray()
	camera_bytes.append_array(_matrix_to_bytes(camera.global_transform.affine_inverse()))
	camera_bytes.append_array(PackedFloat32Array([
		4000.0,
		0.05,
		0.0,
		0.0,
		camera.global_transform.origin.x,
		camera.global_transform.origin.y,
		camera.global_transform.origin.z,
		0.0,
	]).to_byte_array())
	return camera_bytes


func _build_params_bytes() -> PackedByteArray:
	var tan_fovy = tan(deg_to_rad(camera.fov) * 0.5)
	var tan_fovx = tan_fovy * render_texture_size.x / render_texture_size.y
	var focal_y = render_texture_size.y / (2 * tan_fovy)
	var focal_x = render_texture_size.x / (2 * tan_fovx)
	return PackedFloat32Array([
		render_texture_size.x,
		render_texture_size.y,
		tan_fovx,
		tan_fovy,
		focal_x,
		focal_y,
		modifier,
		0, # sh_degree
		float(num_vertex),
	]).to_byte_array()


func _update_camera_and_params_buffers():
	var camera_bytes = _build_camera_buffer_bytes()
	rd.buffer_update(camera_matrices_buffer, 0, camera_bytes.size(), camera_bytes)
	var params_bytes = _build_params_bytes()
	rd.buffer_update(params_buffer, 0, params_bytes.size(), params_bytes)


func _load_ply_file():
	var file = FileAccess.open(splat_filename, FileAccess.READ)
	if not file:
		print("Failed to open file: " + splat_filename)
		return

	var num_properties = 0
	var line = file.get_line()
	while not file.eof_reached():
		if line.begins_with("element vertex"):
			num_vertex = int(line.split(" ")[2])
		elif line.begins_with("property"):
			num_properties += 1
		elif line.begins_with("end_header"):
			break
		line = file.get_line()

	print("num splats: ", num_vertex)
	print("num properties: ", num_properties)
	vertices = file.get_buffer(num_vertex * num_properties * 4).to_float32_array()
	file.close()


func _initialise_framebuffer_format():
	_initialise_screen_texture()
	var tex_format := RDTextureFormat.new()
	var tex_view := RDTextureView.new()
	tex_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tex_format.height = render_texture_size.y
	tex_format.width = render_texture_size.x
	tex_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	tex_format.usage_bits = RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	output_tex = rd.texture_create(tex_format, tex_view)
	display_texture.texture_rd_rid = output_tex

	var attachments = []
	var attachment_format := RDAttachmentFormat.new()
	attachment_format.set_format(tex_format.format)
	attachment_format.set_samples(RenderingDevice.TEXTURE_SAMPLES_1)
	attachment_format.usage_flags = RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	attachments.push_back(attachment_format)
	return rd.framebuffer_format_create(attachments)


func _ready():
	print("unpacking .ply file data...")
	_load_ply_file()
	max_sort_workgroups = max(1, int(ceil(float(num_vertex) / float(SORT_WORKGROUP_SIZE * SORT_BLOCKS_PER_WORKGROUP))))

	print("configuring shaders...")
	var vertices_buffer = rd.storage_buffer_create(vertices.size() * 4, vertices.to_byte_array())
	var params_bytes = _build_params_bytes()
	params_buffer = rd.storage_buffer_create(params_bytes.size(), params_bytes)
	var camera_bytes = _build_camera_buffer_bytes()
	camera_matrices_buffer = rd.storage_buffer_create(camera_bytes.size(), camera_bytes)
	projected_splats_buffer = rd.storage_buffer_create(num_vertex * PROJECTED_SPLAT_FLOATS * 4)
	visible_counter_buffer = rd.storage_buffer_create(4, PackedByteArray([0, 0, 0, 0]))
	sort_key_buffer = rd.storage_buffer_create(num_vertex * 8)
	sort_key_temp_buffer = rd.storage_buffer_create(num_vertex * 8)
	var hist_data := PackedInt32Array()
	hist_data.resize(RADIX_SORT_BINS * max_sort_workgroups)
	histogram_buffer = rd.storage_buffer_create(hist_data.size() * 4, hist_data.to_byte_array(), RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)

	var preprocess_shader_file = load("res://shaders/preprocess_splats.glsl")
	preprocess_shader = rd.shader_create_from_spirv(preprocess_shader_file.get_spirv())
	var radixsort_shader_file = load("res://shaders/multi_radixsort.glsl")
	radixsort_shader = rd.shader_create_from_spirv(radixsort_shader_file.get_spirv())
	var radixsort_hist_shader_file = load("res://shaders/multi_radixsort_histograms.glsl")
	radixsort_hist_shader = rd.shader_create_from_spirv(radixsort_hist_shader_file.get_spirv())
	var shader_file = load("res://shaders/splat.glsl")
	shader = rd.shader_create_from_spirv(shader_file.get_spirv())

	preprocess_pipeline = rd.compute_pipeline_create(preprocess_shader)
	histogram_pipeline = rd.compute_pipeline_create(radixsort_hist_shader)
	sort_pipeline = rd.compute_pipeline_create(radixsort_shader)

	var points := PackedFloat32Array([
		-1, -1, 0,
		1, -1, 0,
		-1, 1, 0,
		1, 1, 0,
	])
	var points_bytes := points.to_byte_array()
	var vertex_buffers := [rd.vertex_buffer_create(points_bytes.size(), points_bytes)]
	var vertex_attrs = [RDVertexAttribute.new()]
	vertex_attrs[0].format = RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
	vertex_attrs[0].location = 0
	vertex_attrs[0].stride = 4 * 3
	vertex_format = rd.vertex_format_create(vertex_attrs)
	vertex_array = rd.vertex_array_create(4, vertex_format, vertex_buffers)

	var blend_attachment = RDPipelineColorBlendStateAttachment.new()
	blend_attachment.enable_blend = true
	blend_attachment.src_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
	blend_attachment.dst_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
	blend_attachment.color_blend_op = RenderingDevice.BLEND_OP_ADD
	blend_attachment.src_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
	blend_attachment.dst_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
	blend_attachment.alpha_blend_op = RenderingDevice.BLEND_OP_ADD
	blend_attachment.write_r = true
	blend_attachment.write_g = true
	blend_attachment.write_b = true
	blend_attachment.write_a = true
	blend.attachments.push_back(blend_attachment)

	var framebuffer_format = _initialise_framebuffer_format()
	framebuffer = rd.framebuffer_create([output_tex], framebuffer_format)

	dynamic_uniform_set_A = rd.uniform_set_create([
		_make_storage_uniform(1, params_buffer),
		_make_storage_uniform(4, sort_key_buffer),
		_make_storage_uniform(5, projected_splats_buffer),
	], shader, 0)
	dynamic_uniform_set_B = rd.uniform_set_create([
		_make_storage_uniform(1, params_buffer),
		_make_storage_uniform(4, sort_key_temp_buffer),
		_make_storage_uniform(5, projected_splats_buffer),
	], shader, 0)
	current_dynamic_uniform_set = dynamic_uniform_set_A

	preprocess_uniform_set0 = rd.uniform_set_create([
		_make_storage_uniform(1, params_buffer),
		_make_storage_uniform(2, visible_counter_buffer),
		_make_storage_uniform(3, camera_matrices_buffer),
		_make_storage_uniform(4, sort_key_buffer),
		_make_storage_uniform(5, projected_splats_buffer),
	], preprocess_shader, 0)
	preprocess_uniform_set1 = rd.uniform_set_create([
		_make_storage_uniform(0, vertices_buffer),
	], preprocess_shader, 1)

	hist_uniform_set_A = rd.uniform_set_create([
		_make_storage_uniform(0, sort_key_buffer),
		_make_storage_uniform(1, histogram_buffer),
	], radixsort_hist_shader, 0)
	hist_uniform_set_B = rd.uniform_set_create([
		_make_storage_uniform(0, sort_key_temp_buffer),
		_make_storage_uniform(1, histogram_buffer),
	], radixsort_hist_shader, 0)

	sort_uniform_set_A = rd.uniform_set_create([
		_make_storage_uniform(0, sort_key_buffer),
		_make_storage_uniform(1, sort_key_temp_buffer),
		_make_storage_uniform(2, histogram_buffer),
	], radixsort_shader, 1)
	sort_uniform_set_B = rd.uniform_set_create([
		_make_storage_uniform(0, sort_key_temp_buffer),
		_make_storage_uniform(1, sort_key_buffer),
		_make_storage_uniform(2, histogram_buffer),
	], radixsort_shader, 1)

	pipeline = rd.render_pipeline_create(
		shader,
		framebuffer_format,
		vertex_format,
		RenderingDevice.RENDER_PRIMITIVE_TRIANGLE_STRIPS,
		RDPipelineRasterizationState.new(),
		RDPipelineMultisampleState.new(),
		RDPipelineDepthStencilState.new(),
		blend
	)

	print("render pipeline valid: ", rd.render_pipeline_is_valid(pipeline))
	print("preprocess pipeline valid: ", rd.compute_pipeline_is_valid(preprocess_pipeline))
	print("sort pipeline valid: ", rd.compute_pipeline_is_valid(sort_pipeline))

	_update_camera_and_params_buffers()
	_rebuild_sort_now()
	render()


func _rebuild_sort_now():
	rd.buffer_update(visible_counter_buffer, 0, 4, PackedByteArray([0, 0, 0, 0]))

	var preprocess_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(preprocess_list, preprocess_pipeline)
	rd.compute_list_bind_uniform_set(preprocess_list, preprocess_uniform_set0, 0)
	rd.compute_list_bind_uniform_set(preprocess_list, preprocess_uniform_set1, 1)
	var preprocess_groups = int(ceil(float(num_vertex) / float(PREPROCESS_WORKGROUP_SIZE)))
	rd.compute_list_dispatch(preprocess_list, preprocess_groups, 1, 1)
	rd.compute_list_end()

	visible_count = rd.buffer_get_data(visible_counter_buffer).to_int32_array()[0]
	current_dynamic_uniform_set = dynamic_uniform_set_A
	
	if visible_count < 2: return

	var num_workgroups = int(ceil(float(visible_count) / float(SORT_WORKGROUP_SIZE * SORT_BLOCKS_PER_WORKGROUP)))
	var compute_list := rd.compute_list_begin()
	for pass_index in range(SORT_PASSES):
		var bit_shift = pass_index * 8
		var push_constant = PackedInt32Array([visible_count, bit_shift, num_workgroups, SORT_BLOCKS_PER_WORKGROUP]).to_byte_array()
		var current_hist_set = hist_uniform_set_A if (pass_index % 2 == 0) else hist_uniform_set_B
		var current_sort_set = sort_uniform_set_A if (pass_index % 2 == 0) else sort_uniform_set_B
		rd.compute_list_bind_compute_pipeline(compute_list, histogram_pipeline)
		rd.compute_list_set_push_constant(compute_list, push_constant, push_constant.size())
		rd.compute_list_bind_uniform_set(compute_list, current_hist_set, 0)
		rd.compute_list_dispatch(compute_list, num_workgroups, 1, 1)
		rd.compute_list_add_barrier(compute_list)
		rd.compute_list_bind_compute_pipeline(compute_list, sort_pipeline)
		rd.compute_list_set_push_constant(compute_list, push_constant, push_constant.size())
		rd.compute_list_bind_uniform_set(compute_list, current_sort_set, 1)
		rd.compute_list_dispatch(compute_list, num_workgroups, 1, 1)
		rd.compute_list_add_barrier(compute_list)
	rd.compute_list_end()

	current_dynamic_uniform_set = dynamic_uniform_set_A if (SORT_PASSES % 2 == 0) else dynamic_uniform_set_B


func update():
	_update_camera_and_params_buffers()
	_rebuild_sort_now()


func render():
	var draw_list := rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_CLEAR_COLOR_ALL, clear_color_values)
	rd.draw_list_bind_render_pipeline(draw_list, pipeline)
	rd.draw_list_bind_uniform_set(draw_list, current_dynamic_uniform_set, 0)
	rd.draw_list_bind_vertex_array(draw_list, vertex_array)
	rd.draw_list_draw(draw_list, false, visible_count)
	rd.draw_list_end()


func _process(_delta):
	update()
	render()


func _input(event):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			modifier += 0.05
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			modifier -= 0.05
