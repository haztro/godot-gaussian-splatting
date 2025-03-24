extends Node3D

@onready var camera = get_node("Camera")
@onready var screen_texture = get_node("TextureRect")
@export var splat_filename: String = "train.ply"

var rd = RenderingServer.get_rendering_device()
var pipeline: RID
var shader: RID
var vertex_format: int
var blend := RDPipelineColorBlendState.new()

var framebuffer: RID
var vertex_array: RID
var index_array: RID
var static_uniform_set: RID
var dynamic_uniform_set: RID
var clear_color_values := PackedColorArray([Color(0,0,0,0)])

var num_coeffs = 45
var num_coeffs_per_color = num_coeffs / 3
var sh_degree = sqrt(num_coeffs_per_color + 1) - 1	

var sort_pipeline: RID
var histogram_pipeline: RID
var depth_in_buffer: RID
var depth_out_buffer: RID
var histogram_buffer: RID
var depth_uniform
var depth_out_uniform
var histogram_uniform_set0
var histogram_uniform_set1
var radixsort_hist_shader: RID
var radixsort_shader: RID
var globalInvocationSize: int


var num_vertex: int
var output_tex: RID

var display_texture:Texture2DRD

var camera_matrices_buffer: RID
var params_buffer: RID
var modifier: float = 1.0
var last_direction := Vector3.ZERO

var vertices: PackedFloat32Array

const NUM_BLOCKS_PER_WORKGROUP = 1024
var NUM_WORKGROUPS


func _matrix_to_bytes(t : Transform3D):
	var basis : Basis = t.basis
	var origin : Vector3 = t.origin
	var bytes : PackedByteArray = PackedFloat32Array([
		basis.x.x, basis.x.y, basis.x.z, 0.0,
		basis.y.x, basis.y.y, basis.y.z, 0.0,
		basis.z.x, basis.z.y, basis.z.z, 0.0,
		origin.x, origin.y, origin.z, 1.0
	]).to_byte_array()
	return bytes


func _initialise_screen_texture():
	display_texture = Texture2DRD.new()
	screen_texture.texture = display_texture


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
	tex_format.height = get_viewport().size.y
	tex_format.width = get_viewport().size.x
	tex_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	tex_format.usage_bits = (RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT)
	output_tex = rd.texture_create(tex_format,tex_view)

	display_texture.texture_rd_rid = output_tex
	
	var attachments = []
	var attachment_format := RDAttachmentFormat.new()
	attachment_format.set_format(tex_format.format)
	attachment_format.set_samples(RenderingDevice.TEXTURE_SAMPLES_1)
	attachment_format.usage_flags = RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	attachments.push_back(attachment_format)	
	var framebuf_format = rd.framebuffer_format_create(attachments)
	return framebuf_format


# Called when the node enters the scene tree for the first time.
func _ready():
	get_viewport().size_changed.connect(_on_viewport_size_changed)

	print("unpacking .ply file data...")
	_load_ply_file()	
	
	print("configuring shaders...")
	var vertices_buffer = rd.storage_buffer_create(vertices.size() * 4, vertices.to_byte_array())
	
	var vertices_uniform = RDUniform.new()
	vertices_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	vertices_uniform.binding = 0
	vertices_uniform.add_id(vertices_buffer)
	
	var depth_in_data = PackedInt32Array()
	for i in range(num_vertex):
		depth_in_data.append_array([0, i])
	depth_in_buffer = rd.storage_buffer_create(num_vertex * 2 * 4, depth_in_data.to_byte_array(), RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	
	depth_uniform = RDUniform.new()
	depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	depth_uniform.binding = 0
	depth_uniform.add_id(depth_in_buffer)
		
	var tan_fovy = tan(deg_to_rad($Camera.fov) * 0.5)
	var tan_fovx = tan_fovy * get_viewport().size.x / get_viewport().size.y
	var focal_y = get_viewport().size.y / (2 * tan_fovy)
	var focal_x = get_viewport().size.x / (2 * tan_fovx)
	
	# Viewport size buffer
	var params : PackedByteArray = PackedFloat32Array([
		get_viewport().size.x,
		get_viewport().size.y,
		tan_fovx,
		tan_fovy,
		focal_x,
		focal_y,
		modifier,
		sh_degree,
	]).to_byte_array()
	params_buffer = rd.storage_buffer_create(params.size(), params)
	var params_uniform := RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	params_uniform.binding = 1
	params_uniform.add_id(params_buffer)
		
	var radixsort_shader_file = load("res://shaders/multi_radixsort.glsl")
	var radixsort_shader_spirv = radixsort_shader_file.get_spirv()
	radixsort_shader = rd.shader_create_from_spirv(radixsort_shader_spirv)

	var radixsort_hist_shader_file = load("res://shaders/multi_radixsort_histograms.glsl")
	var radisxsort_hist_spirv = radixsort_hist_shader_file.get_spirv()
	radixsort_hist_shader = rd.shader_create_from_spirv(radisxsort_hist_spirv)
	
	globalInvocationSize = num_vertex / NUM_BLOCKS_PER_WORKGROUP
	var remainder = num_vertex % NUM_BLOCKS_PER_WORKGROUP
	if remainder > 0:
		globalInvocationSize += 1

	var WORKGROUP_SIZE = 512
	var RADIX_SORT_BINS = 256
	NUM_WORKGROUPS = num_vertex / WORKGROUP_SIZE

	
	var depth_out_data = PackedInt32Array()
	var hist_data = PackedInt32Array()
		
	depth_out_data.resize(num_vertex * 2)
	hist_data.resize(RADIX_SORT_BINS * NUM_WORKGROUPS)
	

	depth_out_buffer = rd.storage_buffer_create(depth_out_data.size() * 4, depth_out_data.to_byte_array(), RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	histogram_buffer = rd.storage_buffer_create(hist_data.size() * 4, hist_data.to_byte_array(), RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	
	depth_out_uniform = RDUniform.new()
	depth_out_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	depth_out_uniform.binding = 1
	depth_out_uniform.add_id(depth_out_buffer)
	
	histogram_uniform_set0 = RDUniform.new()
	histogram_uniform_set0.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	histogram_uniform_set0.binding = 1
	histogram_uniform_set0.add_id(histogram_buffer)	
	
	histogram_uniform_set1 = RDUniform.new()
	histogram_uniform_set1.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	histogram_uniform_set1.binding = 2
	histogram_uniform_set1.add_id(histogram_buffer)	
	
	sort_pipeline = rd.compute_pipeline_create(radixsort_shader)
	histogram_pipeline = rd.compute_pipeline_create(radixsort_hist_shader)

	# Configure splat vertex/frag shader
	var shader_file = load("res://shaders/splat.glsl")
	var shader_spirv = shader_file.get_spirv()
	shader = rd.shader_create_from_spirv(shader_spirv)

	var points := PackedFloat32Array([
		-1,-1,0,
		1,-1,0,
		-1,1,0,
		1,1,0,
	])
	var points_bytes := points.to_byte_array()
	
	var indices := PackedByteArray()
	indices.resize(12)
	var pos = 0
	
	for i in [0,2,1,0,2,3]:
		indices.encode_u16(pos,i)
		pos += 2
		
	var index_buffer = rd.index_buffer_create(6,RenderingDevice.INDEX_BUFFER_FORMAT_UINT16,indices)
	index_array = rd.index_array_create(index_buffer,0,6)
	
	var vertex_buffers := [
		rd.vertex_buffer_create(points_bytes.size(), points_bytes),
	]
	
	var vertex_attrs = [ RDVertexAttribute.new()]
	vertex_attrs[0].format = RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
	vertex_attrs[0].location = 0
	vertex_attrs[0].stride = 4 * 3
	vertex_format = rd.vertex_format_create(vertex_attrs)
	vertex_array = rd.vertex_array_create(4, vertex_format, vertex_buffers)
			
	# Camera Matrices Buffer
	var cam_to_world : Transform3D = camera.global_transform
	var camera_matrices_bytes := PackedByteArray()
	camera_matrices_bytes.append_array(_matrix_to_bytes(cam_to_world))
	camera_matrices_bytes.append_array(PackedFloat32Array([4000.0, 0.05]).to_byte_array())
	camera_matrices_buffer = rd.storage_buffer_create(camera_matrices_bytes.size(), camera_matrices_bytes)
	var camera_matrices_uniform := RDUniform.new()
	camera_matrices_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	camera_matrices_uniform.binding = 3
	camera_matrices_uniform.add_id(camera_matrices_buffer)
	
	
	# Configure blend mode
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
	print("framebuffer valid: ",rd.framebuffer_is_valid(framebuffer))
	
	var static_bindings = [
		vertices_uniform,
	]
	
	var dynamic_bindings = [
		camera_matrices_uniform,
		params_uniform,
		depth_uniform,
	]
	
	dynamic_uniform_set = rd.uniform_set_create(dynamic_bindings, shader, 0)
	static_uniform_set = rd.uniform_set_create(static_bindings, shader, 1)
	
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
	print("compute1 pipeline valid: ", rd.compute_pipeline_is_valid(sort_pipeline))
	
	
	# Do once to ensure splat drawn in correct order at start
	update()
	render()
	radix_sort()


# Reconfigure render pipeline with new viewport size
func _on_viewport_size_changed():
	var framebuf_format = _initialise_framebuffer_format()
	framebuffer = rd.framebuffer_create([output_tex], framebuf_format)
	
	pipeline = rd.render_pipeline_create(
		shader,
		framebuf_format,
		vertex_format,
		RenderingDevice.RENDER_PRIMITIVE_TRIANGLE_STRIPS,
		RDPipelineRasterizationState.new(),
		RDPipelineMultisampleState.new(),
		RDPipelineDepthStencilState.new(),
		blend
	)

	
func radix_sort():
	
	var compute_list := rd.compute_list_begin()
	for i in range(4):
		var push_constant = PackedInt32Array([num_vertex, i * 8, NUM_WORKGROUPS, NUM_BLOCKS_PER_WORKGROUP])
		depth_uniform.clear_ids()
		depth_out_uniform.clear_ids()
		
		if i == 0 or i == 2:
			depth_uniform.add_id(depth_in_buffer)
			depth_out_uniform.add_id(depth_out_buffer)
		else:
			depth_uniform.add_id(depth_out_buffer)
			depth_out_uniform.add_id(depth_in_buffer)
			
		var histogram_bindings = [
			depth_uniform,
			histogram_uniform_set0
		]
		var hist_uniform_set = rd.uniform_set_create(histogram_bindings, radixsort_hist_shader, 0)
		
		rd.compute_list_bind_compute_pipeline(compute_list, histogram_pipeline)
		rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
		rd.compute_list_bind_uniform_set(compute_list, hist_uniform_set, 0)
		rd.compute_list_dispatch(compute_list, globalInvocationSize, 1, 1)
		rd.compute_list_add_barrier(compute_list)
		
		var radixsort_bindings = [
			depth_uniform,
			depth_out_uniform,
			histogram_uniform_set1
		]
		var sort_uniform_set = rd.uniform_set_create(radixsort_bindings, radixsort_shader, 1)
		
		rd.compute_list_bind_compute_pipeline(compute_list, sort_pipeline)
		rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
		rd.compute_list_bind_uniform_set(compute_list, sort_uniform_set, 1)
		rd.compute_list_dispatch(compute_list, globalInvocationSize, 1, 1)
		rd.compute_list_add_barrier(compute_list)
	
	rd.compute_list_end()
	

# Called every frame. 'delta' is the elapsed time since the previous frame.
func update():	
	# Camera Matrices Buffer
	var camera_matrices_bytes := PackedByteArray()
	camera_matrices_bytes.append_array(_matrix_to_bytes(camera.global_transform.affine_inverse()))
	camera_matrices_bytes.append_array(PackedFloat32Array([4000.0, 0.05]).to_byte_array())
	rd.buffer_update(camera_matrices_buffer, 0, camera_matrices_bytes.size(), camera_matrices_bytes)

	var tan_fovy = tan(deg_to_rad($Camera.fov) * 0.5)
	var tan_fovx = tan_fovy * get_viewport().size.x / get_viewport().size.y
	var focal_y = get_viewport().size.y / (2 * tan_fovy)
	var focal_x = get_viewport().size.x / (2 * tan_fovx)

	# Viewport size buffer
	var params : PackedByteArray = PackedFloat32Array([
		get_viewport().size.x,
		get_viewport().size.y,
		tan_fovx,
		tan_fovy,
		focal_x,
		focal_y,
		modifier,
		sh_degree,
	]).to_byte_array()
	rd.buffer_update(params_buffer, 0, params.size(), params)
	
	_sort_splats_by_depth()
	

func render():
	var draw_list := rd.draw_list_begin(framebuffer, RenderingDevice.INITIAL_ACTION_CLEAR, RenderingDevice.FINAL_ACTION_READ, RenderingDevice.INITIAL_ACTION_CLEAR, RenderingDevice.FINAL_ACTION_READ, clear_color_values)
	rd.draw_list_bind_render_pipeline(draw_list, pipeline)
	rd.draw_list_bind_uniform_set(draw_list, dynamic_uniform_set, 0)
	rd.draw_list_bind_uniform_set(draw_list, static_uniform_set, 1)
	rd.draw_list_bind_vertex_array(draw_list, vertex_array)
	rd.draw_list_draw(draw_list, false, num_vertex)
	rd.draw_list_end()

func _process(delta):	
	update()
	render()
	
	
func _input(event):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			modifier += 0.05
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			modifier -= 0.05
		

func _sort_splats_by_depth():
	var direction = camera.global_transform.basis.z.normalized()
	var cos_angle = last_direction.dot(direction)
	var angle = acos(clamp(cos_angle, -1, 1))
	
	# Only re-sort if camera has changed enough
	if angle > 0.2:
		radix_sort()
		last_direction = direction
		
