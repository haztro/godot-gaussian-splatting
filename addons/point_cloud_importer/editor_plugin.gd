@tool
extends EditorPlugin


var point_cloud_importer


func _enter_tree():
	point_cloud_importer = preload("point_cloud_importer.gd").new()
	add_import_plugin(point_cloud_importer)


func _exit_tree():
	remove_import_plugin(point_cloud_importer)
	point_cloud_importer = null
