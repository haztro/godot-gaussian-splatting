class_name PointCloudData extends Resource

static var num_coeffs = 45
static var num_coeffs_per_color = num_coeffs / 3
static var sh_degree = sqrt(num_coeffs_per_color + 1) - 1

@export var positions = PackedFloat32Array()
@export var normals = PackedFloat32Array()
@export var opacities = PackedFloat32Array()
@export var scales = PackedFloat32Array()
@export var rotations = PackedFloat32Array()
@export var sh_coeffs = PackedFloat32Array()
@export var depths = PackedFloat32Array()
@export var depth_index = PackedInt32Array()
@export var num_vertex: int

func _init():
	num_coeffs = 45
	num_coeffs_per_color = num_coeffs / 3
	sh_degree = sqrt(num_coeffs_per_color + 1) - 1


static func load_ply_file(filename: String) -> PointCloudData:
	var point_cloud_data = PointCloudData.new()
	var file = FileAccess.open(filename, FileAccess.READ)

	if not file:
		print("Failed to open file: " + filename)
		return point_cloud_data

	var num_vertex = 0
#num_vertex = 0
	
	# Read header
	var line = file.get_line()
	while not file.eof_reached():
		if line.begins_with("element vertex"):
			num_vertex = int(line.split(" ")[2])
		if line.begins_with("end_header"):
			break
		line = file.get_line()
	
	var coeffs = []

	for i in range(num_vertex):
		var vertex = {
			"x": file.get_float(),
			"y": file.get_float(),
			"z": file.get_float(),
			"nx": file.get_float(),
			"ny": file.get_float(),
			"nz": file.get_float(),
			"f_dc_0": file.get_float(),
			"f_dc_1": file.get_float(),
			"f_dc_2": file.get_float(),
			"f_rest_0": file.get_float(),
			"f_rest_1": file.get_float(),
			"f_rest_2": file.get_float(),
			"f_rest_3": file.get_float(),
			"f_rest_4": file.get_float(),
			"f_rest_5": file.get_float(),
			"f_rest_6": file.get_float(),
			"f_rest_7": file.get_float(),
			"f_rest_8": file.get_float(),
			"f_rest_9": file.get_float(),
			"f_rest_10": file.get_float(),
			"f_rest_11": file.get_float(),
			"f_rest_12": file.get_float(),
			"f_rest_13": file.get_float(),
			"f_rest_14": file.get_float(),
			"f_rest_15": file.get_float(),
			"f_rest_16": file.get_float(),
			"f_rest_17": file.get_float(),
			"f_rest_18": file.get_float(),
			"f_rest_19": file.get_float(),
			"f_rest_20": file.get_float(),
			"f_rest_21": file.get_float(),
			"f_rest_22": file.get_float(),
			"f_rest_23": file.get_float(),
			"f_rest_24": file.get_float(),
			"f_rest_25": file.get_float(),
			"f_rest_26": file.get_float(),
			"f_rest_27": file.get_float(),
			"f_rest_28": file.get_float(),
			"f_rest_29": file.get_float(),
			"f_rest_30": file.get_float(),
			"f_rest_31": file.get_float(),
			"f_rest_32": file.get_float(),
			"f_rest_33": file.get_float(),
			"f_rest_34": file.get_float(),
			"f_rest_35": file.get_float(),
			"f_rest_36": file.get_float(),
			"f_rest_37": file.get_float(),
			"f_rest_38": file.get_float(),
			"f_rest_39": file.get_float(),
			"f_rest_40": file.get_float(),
			"f_rest_41": file.get_float(),
			"f_rest_42": file.get_float(),
			"f_rest_43": file.get_float(),
			"f_rest_44": file.get_float(),
			"opacity": file.get_float(),
			"scale_0": file.get_float(),
			"scale_1": file.get_float(),
			"scale_2": file.get_float(),
			"rot_0": file.get_float(),
			"rot_1": file.get_float(),
			"rot_2": file.get_float(),
			"rot_3": file.get_float()
		}
		
		point_cloud_data.positions.append_array([vertex["x"], vertex["y"], vertex["z"], 0])
		point_cloud_data.opacities.append(vertex["opacity"])
		point_cloud_data.scales.append_array([vertex["scale_0"], vertex["scale_1"], vertex["scale_2"], 0])
		point_cloud_data.rotations.append_array([vertex["rot_0"], vertex["rot_1"], vertex["rot_2"], vertex["rot_3"]])
		point_cloud_data.depth_index.append(i)
		point_cloud_data.depths.append(0)
		
		var coeff = [vertex["f_dc_0"], vertex["f_dc_1"], vertex["f_dc_2"]]
		for j in range(num_coeffs_per_color):
			coeff.append_array([
				vertex["f_rest_%d" % (0 * num_coeffs_per_color + j)],
				vertex["f_rest_%d" % (1 * num_coeffs_per_color + j)],
				vertex["f_rest_%d" % (2 * num_coeffs_per_color + j)]
			])
		point_cloud_data.sh_coeffs.append_array(coeff)
		
	file.close()
	point_cloud_data.num_vertex = num_vertex
	return point_cloud_data
