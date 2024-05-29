# Definición del plugin de importación
@tool
extends EditorImportPlugin

func _get_import_options(path, preset_index: int) -> Array:
	return [
		{
			"name": "Generate Normals",
			"default_value": false
		}
	]

func _get_importer_name() -> String:
	return "point_cloud_importer"

func _get_visible_name() -> String:
	return "Point Cloud Importer"

func _get_recognized_extensions() -> PackedStringArray:
	return ["ply"]

func _get_save_extension() -> String:
	return "tres"

func _get_priority() -> float:
	return 1.0

func _get_import_order() -> int:
	return 0

func _get_resource_type() -> String:
	return "Resource"

func _get_preset_count() -> int:
	return 1

func _get_preset_name(preset: int) -> String:
	return "Default"

func _import(
	source_file: String, 
	save_path: String, 
	options: Dictionary, 
	platform_variants: Array, 
	gen_files: Array
) -> int:
	var point_cloud_data = PointCloudData.load_ply_file(source_file)
	
	var save_result = ResourceSaver.save(point_cloud_data, save_path + ".tres")
	if save_result != OK:
		push_error("Failed to save PointCloudData resource")
		return ERR_CANT_CREATE
	
	return OK

