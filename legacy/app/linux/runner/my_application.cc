#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* lifecycle_channel;
  GtkWindow* window;
  gboolean closing;
  guint close_timeout;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Complete native close only after the shared application flushes its state.
static void finish_close(MyApplication* self) {
  if (self->close_timeout != 0) {
    g_source_remove(self->close_timeout);
    self->close_timeout = 0;
  }
  if (self->window != nullptr) {
    gtk_widget_destroy(GTK_WIDGET(self->window));
    self->window = nullptr;
  }
  g_application_quit(G_APPLICATION(self));
}

static gboolean close_timeout_cb(gpointer data) {
  MyApplication* self = MY_APPLICATION(data);
  self->close_timeout = 0;
  g_print("ownsemble_lifecycle:shutdown_timeout%c", 10);
  finish_close(self);
  return G_SOURCE_REMOVE;
}

static void shutdown_done_cb(GObject* source, GAsyncResult* result, gpointer data) {
  MyApplication* self = MY_APPLICATION(data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response = fl_method_channel_invoke_method_finish(
      FL_METHOD_CHANNEL(source), result, &error);
  if (response != nullptr && FL_IS_METHOD_SUCCESS_RESPONSE(response)) {
  g_print("ownsemble_lifecycle:shutdown_acknowledged%c", 10);
  } else {
  g_print("ownsemble_lifecycle:shutdown_failed%c", 10);
  }
  finish_close(self);
  g_object_unref(self);
}

static gboolean delete_event_cb(GtkWidget*, GdkEvent*, MyApplication* self) {
  if (!self->closing) {
    self->closing = TRUE;
    self->close_timeout = g_timeout_add_full(
        G_PRIORITY_DEFAULT, 8000, close_timeout_cb,
        g_object_ref(self), g_object_unref);
    fl_method_channel_invoke_method(self->lifecycle_channel, "closing", nullptr,
        nullptr, shutdown_done_cb, g_object_ref(self));
  }
  return TRUE;
}

static gboolean close_idle_cb(gpointer data) {
  finish_close(MY_APPLICATION(data));
  return G_SOURCE_REMOVE;
}

static void lifecycle_call_cb(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  MyApplication* self = MY_APPLICATION(data);
  if (g_strcmp0(fl_method_call_get_name(call), "close") == 0) {
    self->closing = TRUE;
    fl_method_call_respond_success(call, nullptr, nullptr);
    g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, close_idle_cb,
        g_object_ref(self), g_object_unref);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
}

// Generated-data native window-close regression; ignored outside --demo mode.
static gboolean lifecycle_smoke_cb(gpointer data) {
  MyApplication* self = MY_APPLICATION(data);
  if (self->window != nullptr) gtk_window_close(self->window);
  return G_SOURCE_REMOVE;
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
  if (g_strv_contains(self->dart_entrypoint_arguments, "--demo") &&
      g_strv_contains(self->dart_entrypoint_arguments, "--lifecycle-smoke")) {
    g_timeout_add_full(G_PRIORITY_DEFAULT, 500, lifecycle_smoke_cb,
        g_object_ref(self), g_object_unref);
  }
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  self->window = window;
  // Intercept before Flutter installs its default native close handler.
  g_signal_connect(window, "delete-event", G_CALLBACK(delete_event_cb), self);

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Ownsemble (Linux)");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Ownsemble (Linux)");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->lifecycle_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "ownsemble/lifecycle", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->lifecycle_channel,
      lifecycle_call_cb, self, nullptr);


  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_object(&self->lifecycle_channel);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
