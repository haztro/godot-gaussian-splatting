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

	
# Called when the node enters the scene tree for the first time.
func _ready():
	$PLYLoader.load_ply("point_cloud.ply")

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
	
	var num_vertex = len(x);
	var max_rot = 0
	
	var data = []
	for i in range(num_vertex):
		var pos = Color(x[i], y[i], z[i], 0.0)
		var sca = Color(opacity[i], scale_0[i], scale_1[i], scale_2[i])
		var rot = Color(rot_0[i], rot_1[i], rot_2[i], rot_3[i])
		var rot_norm = Vector4(rot_0[i], rot_1[i], rot_2[i], rot_3[i]).length()
		if rot_norm > max_rot:
			max_rot = rot_norm;
		data.append(pos)
		data.append(sca)
		data.append(rot)
		
	var pos_tex = pack_texture(4096, data)
	$MultiMeshInstance3D.material_override.set_shader_parameter("data", pos_tex)
	$MultiMeshInstance3D.material_override.set_shader_parameter("tex_width", 4096)
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
		
	var features = []
	for i in range(num_vertex):
		features.append(Color(fdcs[0][i], fdcs[1][i], fdcs[2][i]))
		for j in range(num_coeffs_per_color):
			var c = Color(
				coeffs[0 * num_coeffs_per_color + j][i],
				coeffs[1 * num_coeffs_per_color + j][i],
				coeffs[2 * num_coeffs_per_color + j][i]
				)
			features.append(c)

	fdcs.clear()
	coeffs.clear()

	var sh_tex = pack_texture(4096, features)
	features.clear()
	
	$MultiMeshInstance3D.material_override.set_shader_parameter("sh_data", sh_tex)

	var focal = get_viewport().size / (2 * tan(deg_to_rad($Camera.fov)/2))
	var tan_half_fov = 0.5 * get_viewport().size / focal
	
	$MultiMeshInstance3D.material_override.set_shader_parameter("tan_fovx", tan_half_fov.x)
	$MultiMeshInstance3D.material_override.set_shader_parameter("tan_fovy", tan_half_fov.y)
	$MultiMeshInstance3D.material_override.set_shader_parameter("focal_x", focal.x)
	$MultiMeshInstance3D.material_override.set_shader_parameter("focal_y", focal.y)
	
	$MultiMeshInstance3D.multimesh.instance_count = num_vertex
	$MultiMeshInstance3D.multimesh.visible_instance_count = num_vertex
	for i in range(num_vertex):
		$MultiMeshInstance3D.multimesh.set_instance_transform(i, Transform3D(Basis(), Vector3(x[i], y[i], z[i])))
		

	

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	pass
	

