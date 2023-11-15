extends Node3D


func pack_texture(width, vectors): # vectors is array of Color objects
	var w = width
	var h = max(w, int( floor(vectors.size() / w)) + 1)
	var img = Image.new()
	img = Image.create(w, h, false, Image.FORMAT_RGBAF)
	
	var x: int
	var y: int
	for i in range(vectors.size()):
		y = i / w
		x = i % w
		img.set_pixel(x, y, vectors[i])

	var tex = ImageTexture.new()
	tex = ImageTexture.create_from_image(img)
	return tex
	
func pack_texture_sh(width, fdc, coeffs, num_coeffs_per_color):
	var w = width
	var h = max(w, int( floor(fdc[0].size() / w)) + 1)
	var img = Image.new()
	img = Image.create(w, h, false, Image.FORMAT_RGBAF)
	
	print(w)
	print(h)
	
	var x: int
	var y: int
	var ind = 0
	for i in range(fdc[0].size()):
		y = ind / w
		x = ind % w
		img.set_pixel(x, y, Color(fdc[0][i], fdc[1][i], fdc[2][i]))
		ind += 1
		for j in range(num_coeffs_per_color):
			y = ind / w
			x = ind % w
			var c = Color(
				coeffs[0 * num_coeffs_per_color + j][i],
				coeffs[1 * num_coeffs_per_color + j][i],
				coeffs[2 * num_coeffs_per_color + j][i]
				)
			img.set_pixel(x, y, c)
			ind += 1

	var tex = ImageTexture.new()
	tex = ImageTexture.create_from_image(img)
	return tex


# Called when the node enters the scene tree for the first time.
func _ready():
	$PLYLoader.load_ply("point_cloud1.ply")

	var x = $PLYLoader.get_vertex_property("x")
	var y = $PLYLoader.get_vertex_property("y")
	var z = $PLYLoader.get_vertex_property("z")
	
	var opacity = $PLYLoader.get_vertex_property("opacity")
	var scale_0 = $PLYLoader.get_vertex_property("scale_0")
	var scale_1 = $PLYLoader.get_vertex_property("scale_1")
	var scale_2 = $PLYLoader.get_vertex_property("scale_2")
	
	var rot_0 = $PLYLoader.get_vertex_property("rot_0")
	var rot_1 = $PLYLoader.get_vertex_property("rot_1")
	var rot_2 = $PLYLoader.get_vertex_property("rot_2")
	var rot_3 = $PLYLoader.get_vertex_property("rot_3")
	
	var num_vertex = len(x) / 2;
	var max_rot = 0
	
	var data = []
	for i in range(num_vertex):
		var pos = Color(x[i], y[i], z[i], 0.0)
		var sca = Color(opacity[i], scale_0[i], scale_1[i], scale_2[i])
		var rotn = Vector4(rot_0[i], rot_1[i], rot_2[i], rot_3[i]).normalized()
		var rot = Color(rotn.x, rotn.y, rotn.z, rotn.w)
		data.append(pos)
		data.append(sca)
		data.append(rot)
		
	var pos_tex = pack_texture(10000, data)
	$MultiMeshInstance3D.material_override.set_shader_parameter("data", pos_tex)
	$MultiMeshInstance3D.material_override.set_shader_parameter("tex_width", 10000)
	data.clear()
	opacity.clear()
	scale_0.clear()
	scale_1.clear()
	scale_2.clear()
	rot_0.clear()
	rot_1.clear()
	rot_2.clear()
	rot_3.clear()
	
	var num_coeffs = 45
	var num_coeffs_per_color = num_coeffs / 3
	var sh_degree = sqrt(num_coeffs_per_color + 1) - 1	

	var fdcs = []
	for i in range(3):
		print(("f_dc_%d" % i))
		fdcs.append($PLYLoader.get_vertex_property(("f_dc_%d" % i)))

	var coeffs = []
	for i in range(num_coeffs):
		print("f_rest_%d" % i)
		coeffs.append($PLYLoader.get_vertex_property("f_rest_%d" % i))
		
	var sh_tex = pack_texture_sh(10000, fdcs, coeffs, num_coeffs_per_color)
	fdcs.clear()
	coeffs.clear()
	
	$MultiMeshInstance3D.material_override.set_shader_parameter("sh_data", sh_tex)

	var tan_fovy = tan(deg_to_rad($Camera.fov) * 0.5)
	var tan_fovx = tan_fovy * get_viewport().size.x / get_viewport().size.y
	var focal_y = get_viewport().size.y / (2 * tan_fovy)
	var focal_x = get_viewport().size.x / (2 * tan_fovx)
	
	print(get_viewport().size)
	print(tan_fovy)
	print(tan_fovx)
	print(focal_y)
	print(focal_x)
	
	$MultiMeshInstance3D.material_override.set_shader_parameter("tan_fovx", tan_fovx)
	$MultiMeshInstance3D.material_override.set_shader_parameter("tan_fovy", tan_fovy)
	$MultiMeshInstance3D.material_override.set_shader_parameter("focal_x", focal_x)
	$MultiMeshInstance3D.material_override.set_shader_parameter("focal_y", focal_y)
	
	$MultiMeshInstance3D.multimesh.instance_count = num_vertex
	$MultiMeshInstance3D.multimesh.visible_instance_count = num_vertex
	for i in range(num_vertex):
		$MultiMeshInstance3D.multimesh.set_instance_transform(i, Transform3D(Basis(), Vector3(x[i], y[i], z[i])))
		

	

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	pass
	

