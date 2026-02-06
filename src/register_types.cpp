#include "register_types.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include "yggdrasil_peer.h"

using namespace godot;

static void _register_yggdrasil_project_settings() {
	ProjectSettings *ps = ProjectSettings::get_singleton();
	if (!ps) {
		return;
	}

	// yggdrasil/transport/protocol — default "quic"
	const String setting_name = "yggdrasil/transport/protocol";
	if (!ps->has_setting(setting_name)) {
		ps->set_setting(setting_name, "quic");
	}
	ps->set_initial_value(setting_name, "quic");

	Dictionary hint;
	hint["name"] = setting_name;
	hint["type"] = Variant::STRING;
	hint["hint"] = PROPERTY_HINT_ENUM;
	hint["hint_string"] = "quic,tls,tcp,ws,wss";
	ps->add_property_info(hint);
}

void initialize_yggdrasil_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	ClassDB::register_class<YggdrasilPeer>();
	_register_yggdrasil_project_settings();
}

void uninitialize_yggdrasil_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
}

extern "C" {

GDExtensionBool GDE_EXPORT yggdrasil_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		const GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

	init_obj.register_initializer(initialize_yggdrasil_module);
	init_obj.register_terminator(uninitialize_yggdrasil_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

	return init_obj.init();
}
}
