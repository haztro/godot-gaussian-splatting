extends Node3D

@onready var camera = get_node("Camera")
@onready var screen_texture = get_node("TextureRect")
#@export var splat_filename: String = "point_cloud3.ply"
@export var splatResource: PointCloudData #= preload("res://point_cloud.ply")

var rd = RenderingServer.create_local_rendering_device()
var pipeline: RID
var shader: RID
var vertex_format: int
var blend := RDPipelineColorBlendState.new()

var framebuffer: RID
var vertex_array: RID
var index_array: RID
var uniform_set: RID
var clear_color_values := PackedColorArray([Color(0,0,0,0)])

var depths = PackedFloat32Array()
var depth_index = PackedInt32Array()

var positions = PackedFloat32Array()
var opacities = PackedFloat32Array()
var scales = PackedFloat32Array()
var rotations = PackedFloat32Array()
var sh_coeffs = PackedFloat32Array()

var num_coeffs = 45
var num_coeffs_per_color = num_coeffs / 3
var sh_degree = sqrt(num_coeffs_per_color + 1) - 1	

var sort_uniform_set: RID
var sort_pipeline: RID
var sort2_uniform_set: RID
var sort2_pipeline: RID

var num_vertex: int
var output_tex: RID

var camera_matrices_buffer: RID
var params_buffer: RID
var modifier: float = 1.0
var last_direction := Vector3.ZERO


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


func _pad_to_next_power_2(array, val):
	var original_length = array.size()
	var next_power_of_2 = 1
	while next_power_of_2 < original_length:
		next_power_of_2 <<= 1

	var needed_padding = next_power_of_2 - original_length
	for i in range(needed_padding):
		array.append(val)

	return array


func _initialise_screen_texture():
	var image_size = get_viewport().size
	var image = Image.create(image_size.x, image_size.y, false, Image.FORMAT_RGBAF)
	var image_texture = ImageTexture.create_from_image(image)
	screen_texture.texture = image_texture
	
	
func _set_screen_texture_data(data: PackedByteArray):
	var image_size = get_viewport().size
	var image := Image.create_from_data(image_size.x, image_size.y, false, Image.FORMAT_RGBAF, data)
	screen_texture.texture.update(image)



# terrible loading
func _load_ply_file():
	
	depths = splatResource.depths
	depth_index = splatResource.depth_index
	positions = splatResource.positions
	opacities = splatResource.opacities
	scales = splatResource.scales
	rotations = splatResource.rotations
	sh_coeffs = splatResource.sh_coeffs
	num_vertex =  splatResource.num_vertex
	

func _initialise_framebuffer_format():
	_initialise_screen_texture()
	var tex_format := RDTextureFormat.new()
	var tex_view := RDTextureView.new()
	tex_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tex_format.height = get_viewport().size.y
	tex_format.width = get_viewport().size.x
	tex_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	tex_format.usage_bits = (RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT) 
	output_tex = rd.texture_create(tex_format,tex_view)

	var attachments = []
	var attachment_format := RDAttachmentFormat.new()
	attachment_format.set_format(tex_format.format)
	attachment_format.set_samples(RenderingDevice.TEXTURE_SAMPLES_1)
	attachment_format.usage_flags = RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	attachments.push_back(attachment_format)	
	var framebuf_format = rd.framebuffer_format_create(attachments)
	return framebuf_format


# Called when the node enters the scene tree for the first time.
func _ready():
	get_viewport().size_changed.connect(_on_viewport_size_changed)

	print("unpacking .ply file data...")
	_load_ply_file()
	print("num splats: ", num_vertex)
	
	
	# Arrays need to be powers of 2 in length for bitonic sort
	_pad_to_next_power_2(depth_index, 0)
	_pad_to_next_power_2(depths, INF)
	
	print("configuring shaders...")
	var depth_buffer = rd.storage_buffer_create(depths.size() * 4, depths.to_byte_array())
	var depth_index_buffer = rd.storage_buffer_create(depth_index.size() * 4, depth_index.to_byte_array())
	var position_buffer = rd.storage_buffer_create(positions.size() * 4, positions.to_byte_array())
	var opacity_buffer = rd.storage_buffer_create(opacities.size() * 4, opacities.to_byte_array())
	var scale_buffer = rd.storage_buffer_create(scales.size() * 4, scales.to_byte_array())
	var rotation_buffer = rd.storage_buffer_create(rotations.size() * 4, rotations.to_byte_array())
	var sh_coeff_buffer = rd.storage_buffer_create(sh_coeffs.size() * 4, sh_coeffs.to_byte_array())
	
	# Configure bitonic sort shaders
	var sort_shader_file = load("res://shaders/sort.glsl")
	var sort_shader_spirv = sort_shader_file.get_spirv()
	var sort_shader := rd.shader_create_from_spirv(sort_shader_spirv)
	
	var sort2_shader_file = load("res://shaders/sort2.glsl")
	var sort2_shader_spirv = sort2_shader_file.get_spirv()
	var sort2_shader := rd.shader_create_from_spirv(sort2_shader_spirv)
	
	var depth_uniform = RDUniform.new()
	depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	depth_uniform.binding = 7
	depth_uniform.add_id(depth_buffer)
	
	var depth_index_uniform = RDUniform.new()
	depth_index_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	depth_index_uniform.binding = 8
	depth_index_uniform.add_id(depth_index_buffer)
	
	var sort_bindings = [
		depth_uniform,
		depth_index_uniform,
	]
		
	sort_uniform_set = rd.uniform_set_create(sort_bindings, sort_shader, 0)
	sort_pipeline = rd.compute_pipeline_create(sort_shader)
	sort2_pipeline = rd.compute_pipeline_create(sort2_shader)	

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
	camera_matrices_uniform.binding = 0
	camera_matrices_uniform.add_id(camera_matrices_buffer)
	
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
	]).to_byte_array()
	params_buffer = rd.storage_buffer_create(params.size(), params)
	var params_uniform := RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	params_uniform.binding = 1
	params_uniform.add_id(params_buffer)
	
	# Vertex uniform storage buffers
	var position_uniform = RDUniform.new()
	position_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	position_uniform.binding = 2
	position_uniform.add_id(position_buffer)
	
	var coeffs_uniform = RDUniform.new()
	coeffs_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	coeffs_uniform.binding = 3
	coeffs_uniform.add_id(sh_coeff_buffer)
	
	var scales_uniform = RDUniform.new()
	scales_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	scales_uniform.binding = 4
	scales_uniform.add_id(scale_buffer)
	
	var opacity_uniform = RDUniform.new()
	opacity_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	opacity_uniform.binding = 5
	opacity_uniform.add_id(opacity_buffer)
	
	var rotation_uniform = RDUniform.new()
	rotation_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	rotation_uniform.binding = 6
	rotation_uniform.add_id(rotation_buffer)
	
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
	
	var bindings = [
		camera_matrices_uniform,
		params_uniform,
		position_uniform,
		coeffs_uniform,
		scales_uniform,
		opacity_uniform,
		rotation_uniform,
		depth_uniform,
		depth_index_uniform,
	]
	uniform_set = rd.uniform_set_create(bindings, shader, 0)
	
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
	print("compute2 pipeline valid: ", rd.compute_pipeline_is_valid(sort2_pipeline))

	# Do once to ensure splat drawn in correct order at start
	update()
	render()
	bitonic_sort()


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

	
# Adapted from:
# https://github.com/9ballsyndrome/WebGL_Compute_shader/tree/master/webgl-compute-bitonicSort
func bitonic_sort():
	var threads_per_grid: int = max(1, depth_index.size() / 1024)
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, sort_pipeline)
	rd.compute_list_bind_uniform_set(compute_list, sort_uniform_set, 0)
	rd.compute_list_dispatch(compute_list, threads_per_grid, 1, 1)
	rd.compute_list_add_barrier(compute_list)

	var k: int = threads_per_grid
	while k <= depth_index.size():
		var j = k / 2
		while j > 0:
			var push_constant = PackedInt32Array([k, j, 0, 0])
			rd.compute_list_bind_compute_pipeline(compute_list, sort2_pipeline)
			rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
			rd.compute_list_bind_uniform_set(compute_list, sort_uniform_set, 0)
			rd.compute_list_dispatch(compute_list, threads_per_grid, 1, 1)
			rd.compute_list_add_barrier(compute_list)
			j /= 2 
		k *= 2
	
	rd.compute_list_end()
	rd.submit()
	rd.sync()


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
	]).to_byte_array()
	rd.buffer_update(params_buffer, 0, params.size(), params)
	
	#bitonic_sort()
	_sort_splats_by_depth()
	

func render():
	var draw_list := rd.draw_list_begin(framebuffer, RenderingDevice.INITIAL_ACTION_CLEAR, RenderingDevice.FINAL_ACTION_READ, RenderingDevice.INITIAL_ACTION_CLEAR, RenderingDevice.FINAL_ACTION_READ, clear_color_values)
	rd.draw_list_bind_render_pipeline(draw_list, pipeline)
	rd.draw_list_bind_uniform_set(draw_list, uniform_set, 0)
	rd.draw_list_bind_vertex_array(draw_list, vertex_array)
	#rd.draw_list_bind_index_array(draw_list,index_array)
	rd.draw_list_draw(draw_list, false, num_vertex)
	rd.draw_list_end(RenderingDevice.BARRIER_MASK_VERTEX)
	
	var byte_data := rd.texture_get_data(output_tex,0)
	_set_screen_texture_data(byte_data)


func _process(_delta):	
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
	if angle > 0.6:
		bitonic_sort()
		last_direction = direction
