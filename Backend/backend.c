/* GPL-3.0-or-later: isolated libpurple 2 backend. stdout is IPC only. */
#include <fcntl.h>
#include <dlfcn.h>
#include <json-glib/json-glib.h>
#include <purple.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#define UI "adium-dynamic-purple"
#ifndef ADP_VERSION
#define ADP_VERSION "0.2.1"
#endif
static GMainLoop *loop;
static GHashTable *accounts, *requests, *failures, *snapshots;
static void account_updated(PurpleAccount *a);
static guint serial;
static int ipc_fd;
static gboolean stopping;
static const char *str(JsonObject *o, const char *k) {
  JsonNode *n = o ? json_object_get_member(o, k) : NULL;
  return n && JSON_NODE_HOLDS_VALUE(n) &&
                 json_node_get_value_type(n) == G_TYPE_STRING
             ? json_node_get_string(n)
             : "";
}
static int num(JsonObject *o, const char *k) {
  JsonNode *n = o ? json_object_get_member(o, k) : NULL;
  return n && JSON_NODE_HOLDS_VALUE(n) &&
                 json_node_get_value_type(n) != G_TYPE_STRING
             ? (int)json_node_get_int(n)
             : 0;
}
static JsonObject *obj(JsonObject *o, const char *k) {
  JsonNode *n = o ? json_object_get_member(o, k) : NULL;
  return n && JSON_NODE_HOLDS_OBJECT(n) ? json_node_get_object(n) : NULL;
}
static void s(JsonObject *o, const char *k, const char *v) {
  json_object_set_string_member(o, k, v ? v : "");
}
static void i(JsonObject *o, const char *k, gint64 v) {
  json_object_set_int_member(o, k, v);
}
static void b(JsonObject *o, const char *k, gboolean v) {
  json_object_set_boolean_member(o, k, v);
}
static const char *aid(PurpleAccount *a) {
  return a && a->ui_data ? a->ui_data : "";
}
static JsonObject *event(const char *name, PurpleAccount *a) {
  JsonObject *o = json_object_new();
  s(o, "event", name);
  if (a)
    s(o, "account", aid(a));
  return o;
}
static void emit(JsonObject *o) {
  JsonNode *n = json_node_new(JSON_NODE_OBJECT);
  json_node_take_object(n, o);
  JsonGenerator *g = json_generator_new();
  json_generator_set_root(g, n);
  gchar *line = json_generator_to_data(g, NULL),
        *wire = g_strconcat(line, "\n", NULL);
  gsize len = strlen(wire), off = 0;
  while (off < len) {
    ssize_t w = write(ipc_fd, wire + off, len - off);
    if (w <= 0) {
      stopping = TRUE;
      g_main_loop_quit(loop);
      break;
    }
    off += w;
  }
  g_free(wire);
  g_free(line);
  g_object_unref(g);
  json_node_free(n);
}
static void error_event(const char *text, PurpleAccount *a) {
  JsonObject *o = event("notification", a);
  s(o, "title", "Backend");
  s(o, "primary", text);
  s(o, "level", "error");
  emit(o);
}
/* Protocol debug output may contain credentials or message bodies. Drop it. */
static void debug_print(PurpleDebugLevel l, const char *c, const char *m) {
  (void)l;
  (void)c;
  (void)m;
}
typedef struct {
  PurpleInputFunction cb;
  gpointer data;
  int fd;
} Watch;
static gboolean input_cb(GIOChannel *c, GIOCondition cond, gpointer data) {
  Watch *w = data;
  PurpleInputCondition p = 0;
  (void)c;
  if (cond & (G_IO_IN | G_IO_HUP | G_IO_ERR | G_IO_NVAL))
    p |= PURPLE_INPUT_READ;
  if (cond & (G_IO_OUT | G_IO_HUP | G_IO_ERR | G_IO_NVAL))
    p |= PURPLE_INPUT_WRITE;
  w->cb(w->data, w->fd, p);
  return TRUE;
}
static guint input_add(int fd, PurpleInputCondition p, PurpleInputFunction cb,
                       gpointer data) {
  Watch *w = g_new0(Watch, 1);
  w->cb = cb;
  w->data = data;
  w->fd = fd;
  GIOChannel *c = g_io_channel_unix_new(fd);
  GIOCondition cond = G_IO_HUP | G_IO_ERR | G_IO_NVAL;
  if (p & PURPLE_INPUT_READ)
    cond |= G_IO_IN;
  if (p & PURPLE_INPUT_WRITE)
    cond |= G_IO_OUT;
  guint id =
      g_io_add_watch_full(c, G_PRIORITY_DEFAULT, cond, input_cb, w, g_free);
  g_io_channel_unref(c);
  return id;
}
static PurpleEventLoopUiOps eloop = {.timeout_add = g_timeout_add,
                                     .timeout_remove = g_source_remove,
                                     .input_add = input_add,
                                     .input_remove = g_source_remove,
                                     .timeout_add_seconds =
                                         g_timeout_add_seconds};
static void chat_info(PurpleConnection *gc) {
  PurpleAccount *a = purple_connection_get_account(gc);
  PurplePlugin *plugin = purple_find_prpl(purple_account_get_protocol_id(a));
  PurplePluginProtocolInfo *info =
      plugin ? PURPLE_PLUGIN_PROTOCOL_INFO(plugin) : NULL;
  JsonObject *o = event("chatInfo", a);
  JsonArray *fields = json_array_new();
  if (info && info->chat_info) {
    GList *entries = info->chat_info(gc);
    GHashTable *defaults =
        info->chat_info_defaults ? info->chat_info_defaults(gc, NULL) : NULL;
    for (GList *l = entries; l; l = l->next) {
      struct proto_chat_entry *entry = l->data;
      const char *value =
          defaults ? g_hash_table_lookup(defaults, entry->identifier) : NULL;
      JsonObject *field = json_object_new();
      s(field, "key", entry->identifier);
      s(field, "label", entry->label);
      s(field, "type", entry->is_int ? "int" : "string");
      b(field, "required", entry->required);
      b(field, "masked", entry->secret);
      if (entry->is_int) {
        i(field, "default",
          value ? g_ascii_strtoll(value, NULL, 10) : entry->min);
        i(field, "min", entry->min);
        i(field, "max", entry->max);
      } else
        s(field, "default", value);
      json_array_add_object_element(fields, field);
      /* label and identifier belong to the protocol, only the entry is owned.
       */
      g_free(entry);
    }
    g_list_free(entries);
    if (defaults)
      g_hash_table_destroy(defaults);
  }
  json_object_set_array_member(o, "fields", fields);
  emit(o);
}
static void connected(PurpleConnection *gc) {
  emit(event("connected", purple_connection_get_account(gc)));
  account_updated(purple_connection_get_account(gc));
  chat_info(gc);
}
static void connection_error(PurpleConnection *gc, PurpleConnectionError reason,
                             const char *text) {
  JsonObject *o = event("disconnected", purple_connection_get_account(gc));
  i(o, "reason", reason);
  s(o, "error", text);
  g_hash_table_replace(failures, purple_connection_get_account(gc), o);
}
static void disconnected(PurpleConnection *gc) {
  PurpleAccount *a = purple_connection_get_account(gc);
  account_updated(a);
  JsonObject *o = g_hash_table_lookup(failures, a);
  if (o)
    g_hash_table_steal(failures, a);
  else {
    o = event("disconnected", a);
    i(o, "reason", 0);
    s(o, "error", "");
  }
  emit(o);
}
static PurpleConnectionUiOps cops = {.connected = connected,
                                     .disconnected = disconnected,
                                     .report_disconnect_reason =
                                         connection_error};
static void write_message(PurpleConversation *c, const char *who,
                          const char *message, PurpleMessageFlags flags,
                          time_t t) {
  gboolean chat = purple_conversation_get_type(c) == PURPLE_CONV_TYPE_CHAT;
  JsonObject *o =
      event(chat ? "chatMessage" : "im", purple_conversation_get_account(c));
  s(o, "from", who);
  s(o, "message", message);
  i(o, "flags", flags);
  i(o, "time", t);
  if (chat)
    i(o, "chat", purple_conv_chat_get_id(PURPLE_CONV_CHAT(c)));
  else
    s(o, "peer", purple_conversation_get_name(c));
  emit(o);
}
static void write_conv(PurpleConversation *c, const char *who,
                       const char *alias, const char *m, PurpleMessageFlags f,
                       time_t t) {
  (void)alias;
  write_message(c, who, m, f, t);
}
static void chat_buddy(PurpleConversation *c, const char *name,
                       const char *alias, const char *action) {
  JsonObject *o = event("chatBuddy", purple_conversation_get_account(c));
  i(o, "chat", purple_conv_chat_get_id(PURPLE_CONV_CHAT(c)));
  s(o, "name", name);
  s(o, "alias", alias);
  s(o, "action", action);
  emit(o);
}
static void chat_add(PurpleConversation *c, GList *users, gboolean arrivals) {
  (void)arrivals;
  for (; users; users = users->next) {
    PurpleConvChatBuddy *u = users->data;
    chat_buddy(c, u->name, u->alias, "add");
  }
}
static void chat_remove(PurpleConversation *c, GList *users) {
  for (; users; users = users->next)
    chat_buddy(c, users->data, NULL, "remove");
}
static void chat_rename(PurpleConversation *c, const char *old,
                        const char *name, const char *alias) {
  chat_buddy(c, old, NULL, "remove");
  chat_buddy(c, name, alias, "add");
}
static void chat_update(PurpleConversation *c, const char *name) {
  chat_buddy(c, name, name, "update");
}
static PurpleConversationUiOps convops = {.write_im = write_message,
                                          .write_chat = write_message,
                                          .write_conv = write_conv,
                                          .chat_add_users = chat_add,
                                          .chat_remove_users = chat_remove,
                                          .chat_rename_user = chat_rename,
                                          .chat_update_user = chat_update};
static void chat_joined(PurpleConversation *c, gpointer unused) {
  (void)unused;
  JsonObject *o = event("chatJoined", purple_conversation_get_account(c));
  i(o, "chat", purple_conv_chat_get_id(PURPLE_CONV_CHAT(c)));
  s(o, "name", purple_conversation_get_name(c));
  emit(o);
}
static void chat_left(PurpleConversation *c, gpointer unused) {
  (void)unused;
  JsonObject *o = event("chatLeft", purple_conversation_get_account(c));
  i(o, "chat", purple_conv_chat_get_id(PURPLE_CONV_CHAT(c)));
  emit(o);
}
static void typing_event(PurpleAccount *a, const char *who, gpointer state) {
  JsonObject *o = event("typing", a);
  s(o, "from", who);
  i(o, "state", GPOINTER_TO_INT(state));
  emit(o);
}
static void buddy_update(PurpleBuddyList *list, PurpleBlistNode *node) {
  (void)list;
  if (!PURPLE_BLIST_NODE_IS_BUDDY(node))
    return;
  PurpleBuddy *buddy = (PurpleBuddy *)node;
  PurpleStatus *status =
      purple_presence_get_active_status(purple_buddy_get_presence(buddy));
  JsonObject *o = event("buddy", purple_buddy_get_account(buddy));
  s(o, "name", purple_buddy_get_name(buddy));
  s(o, "alias", purple_buddy_get_alias(buddy));
  b(o, "online", PURPLE_BUDDY_IS_ONLINE(buddy));
  s(o, "status", status ? purple_status_get_id(status) : "offline");
  s(o, "statusMessage",
    status ? purple_status_get_attr_string(status, "message") : "");
  emit(o);
}
static PurpleBlistUiOps blistops = {.update = buddy_update};
static void *notify_message(PurpleNotifyMsgType type, const char *title,
                            const char *primary, const char *secondary) {
  JsonObject *o = event("notification", NULL);
  s(o, "title", title);
  s(o, "primary", primary);
  s(o, "secondary", secondary);
  i(o, "type", type);
  emit(o);
  return NULL;
}
static void *notify_uri(const char *uri) {
  JsonObject *o = event("notification", NULL);
  s(o, "type", "uri");
  s(o, "uri", uri);
  emit(o);
  return NULL;
}
static void *notify_formatted(const char *t, const char *p, const char *s2,
                              const char *text) {
  JsonObject *o = event("notification", NULL);
  s(o, "title", t);
  s(o, "primary", p);
  s(o, "secondary", s2);
  s(o, "message", text);
  emit(o);
  return NULL;
}
static PurpleNotifyUiOps notifyops = {.notify_message = notify_message,
                                      .notify_uri = notify_uri,
                                      .notify_formatted = notify_formatted};
typedef struct {
  char *id;
  PurpleRequestType type;
  PurpleAccount *account;
  gpointer data;
  GCallback ok, cancel;
  GPtrArray *callbacks;
  PurpleRequestFields *fields;
  gboolean closing;
} Request;
static void request_free(Request *r) {
  if (r->fields)
    purple_request_fields_destroy(r->fields);
  if (r->callbacks)
    g_ptr_array_free(r->callbacks, TRUE);
  g_free(r->id);
  g_free(r);
}
static void request_close(PurpleRequestType type, void *handle) {
  Request *r = handle;
  (void)type;
  if (!r)
    return;
  JsonObject *o = event("requestClosed", r->account);
  s(o, "request", r->id);
  emit(o);
  g_hash_table_remove(requests, r->id);
  request_free(r);
}
static Request *request_new(PurpleRequestType type, PurpleAccount *a,
                            void *data) {
  Request *r = g_new0(Request, 1);
  r->id = g_strdup_printf("%u", ++serial);
  r->type = type;
  r->account = a;
  r->data = data;
  g_hash_table_insert(requests, r->id, r);
  return r;
}
static JsonObject *request_event(Request *r, const char *title,
                                 const char *primary, const char *secondary) {
  JsonObject *o = event("request", r->account);
  s(o, "request", r->id);
  s(o, "title", title);
  s(o, "primary", primary);
  s(o, "secondary", secondary);
  return o;
}
static void action(JsonArray *actions, const char *label, int index) {
  JsonObject *o = json_object_new();
  s(o, "label", label);
  i(o, "index", index);
  json_array_add_object_element(actions, o);
}
static void two_actions(JsonObject *o, const char *ok, const char *cancel) {
  JsonArray *a = json_array_new();
  action(a, ok ? ok : "OK", 0);
  action(a, cancel ? cancel : "Cancel", 1);
  json_object_set_array_member(o, "actions", a);
}
static void *request_input(const char *t, const char *p, const char *sec,
                           const char *def, gboolean multi, gboolean masked,
                           gchar *hint, const char *ok, GCallback okcb,
                           const char *cancel, GCallback cancelcb,
                           PurpleAccount *a, const char *who,
                           PurpleConversation *conv, void *data) {
  (void)multi;
  (void)hint;
  (void)who;
  (void)conv;
  Request *r = request_new(PURPLE_REQUEST_INPUT, a, data);
  r->ok = okcb;
  r->cancel = cancelcb;
  JsonObject *o = request_event(r, t, p, sec), *f = json_object_new();
  JsonArray *fields = json_array_new();
  s(f, "id", "value");
  s(f, "label", p);
  s(f, "type", "string");
  s(f, "value", def);
  b(f, "masked", masked);
  b(f, "required", FALSE);
  json_array_add_object_element(fields, f);
  json_object_set_array_member(o, "fields", fields);
  two_actions(o, ok, cancel);
  emit(o);
  return r;
}
static void *request_action(const char *t, const char *p, const char *sec,
                            int def, PurpleAccount *a, const char *who,
                            PurpleConversation *conv, void *data, size_t count,
                            va_list args) {
  (void)who;
  (void)conv;
  Request *r = request_new(PURPLE_REQUEST_ACTION, a, data);
  r->callbacks = g_ptr_array_new();
  JsonObject *o = request_event(r, t, p, sec);
  JsonArray *actions = json_array_new();
  for (size_t j = 0; j < count; j++) {
    const char *label = va_arg(args, const char *);
    GCallback cb = va_arg(args, GCallback);
    action(actions, label, (int)j);
    g_ptr_array_add(r->callbacks, cb);
  }
  i(o, "defaultAction", def);
  json_object_set_array_member(o, "actions", actions);
  json_object_set_array_member(o, "fields", json_array_new());
  emit(o);
  return r;
}
static void *request_action_icon(const char *t, const char *p, const char *sec,
                                 int def, PurpleAccount *a, const char *who,
                                 PurpleConversation *conv, gconstpointer icon,
                                 gsize size, void *data, size_t count,
                                 va_list args) {
  (void)icon;
  (void)size;
  return request_action(t, p, sec, def, a, who, conv, data, count, args);
}
static void field_choices(JsonObject *o, GList *items, gboolean indexed) {
  JsonArray *values = json_array_new();
  int j = 0;
  for (; items; items = items->next, j++) {
    JsonObject *v = json_object_new();
    s(v, "label", items->data);
    if (indexed)
      i(v, "value", j);
    else
      s(v, "value", items->data);
    json_array_add_object_element(values, v);
  }
  json_object_set_array_member(o, "values", values);
}
static JsonObject *field_json(PurpleRequestField *f) {
  JsonObject *o = json_object_new();
  PurpleRequestFieldType type = purple_request_field_get_type(f);
  s(o, "id", purple_request_field_get_id(f));
  s(o, "label", purple_request_field_get_label(f));
  b(o, "required", purple_request_field_is_required(f));
  b(o, "masked", FALSE);
  switch (type) {
  case PURPLE_REQUEST_FIELD_BOOLEAN:
    s(o, "type", "bool");
    b(o, "value", purple_request_field_bool_get_value(f));
    break;
  case PURPLE_REQUEST_FIELD_INTEGER:
    s(o, "type", "int");
    i(o, "value", purple_request_field_int_get_value(f));
    break;
  case PURPLE_REQUEST_FIELD_CHOICE:
    s(o, "type", "list");
    i(o, "value", purple_request_field_choice_get_value(f));
    field_choices(o, purple_request_field_choice_get_labels(f), TRUE);
    break;
  case PURPLE_REQUEST_FIELD_LIST: {
    s(o, "type", "list");
    GList *sel = purple_request_field_list_get_selected(f);
    s(o, "value", sel ? sel->data : "");
    field_choices(o, purple_request_field_list_get_items(f), FALSE);
    b(o, "multiple", purple_request_field_list_get_multi_select(f));
    break;
  }
  case PURPLE_REQUEST_FIELD_STRING:
    s(o, "type", "string");
    s(o, "value", purple_request_field_string_get_value(f));
    b(o, "masked", purple_request_field_string_is_masked(f));
    break;
  default:
    s(o, "type", "string");
    s(o, "value", "");
    b(o, "readOnly", TRUE);
    break;
  }
  return o;
}
static void *request_fields(const char *t, const char *p, const char *sec,
                            PurpleRequestFields *fields, const char *ok,
                            GCallback okcb, const char *cancel,
                            GCallback cancelcb, PurpleAccount *a,
                            const char *who, PurpleConversation *conv,
                            void *data) {
  (void)who;
  (void)conv;
  Request *r = request_new(PURPLE_REQUEST_FIELDS, a, data);
  r->fields = fields;
  r->ok = okcb;
  r->cancel = cancelcb;
  JsonObject *o = request_event(r, t, p, sec);
  JsonArray *array = json_array_new();
  for (GList *g = purple_request_fields_get_groups(fields); g; g = g->next)
    for (GList *f = purple_request_field_group_get_fields(g->data); f;
         f = f->next)
      if (purple_request_field_is_visible(f->data))
        json_array_add_object_element(array, field_json(f->data));
  json_object_set_array_member(o, "fields", array);
  two_actions(o, ok, cancel);
  emit(o);
  return r;
}
static void *request_choice(const char *t, const char *p, const char *sec,
                            int def, const char *ok, GCallback okcb,
                            const char *cancel, GCallback cancelcb,
                            PurpleAccount *a, const char *who,
                            PurpleConversation *conv, void *data,
                            va_list args) {
  (void)who;
  (void)conv;
  Request *r = request_new(PURPLE_REQUEST_CHOICE, a, data);
  r->ok = okcb;
  r->cancel = cancelcb;
  JsonObject *o = request_event(r, t, p, sec), *f = json_object_new();
  JsonArray *fields = json_array_new(), *values = json_array_new();
  const char *label;
  s(f, "id", "value");
  s(f, "label", p);
  s(f, "type", "list");
  i(f, "value", def);
  while ((label = va_arg(args, const char *))) {
    int value = va_arg(args, int);
    JsonObject *v = json_object_new();
    s(v, "label", label);
    i(v, "value", value);
    json_array_add_object_element(values, v);
  }
  json_object_set_array_member(f, "values", values);
  json_array_add_object_element(fields, f);
  json_object_set_array_member(o, "fields", fields);
  two_actions(o, ok, cancel);
  emit(o);
  return r;
}
static PurpleRequestUiOps requestops = {.request_input = request_input,
                                        .request_action = request_action,
                                        .request_fields = request_fields,
                                        .request_choice = request_choice,
                                        .close_request = request_close,
                                        .request_action_with_icon =
                                            request_action_icon};
static gboolean set_fields(Request *r, JsonObject *values) {
  for (GList *g = purple_request_fields_get_groups(r->fields); g; g = g->next)
    for (GList *l = purple_request_field_group_get_fields(g->data); l;
         l = l->next) {
      PurpleRequestField *f = l->data;
      const char *id = purple_request_field_get_id(f);
      if (!values || !json_object_has_member(values, id))
        continue;
      switch (purple_request_field_get_type(f)) {
      case PURPLE_REQUEST_FIELD_STRING:
        purple_request_field_string_set_value(f, str(values, id));
        break;
      case PURPLE_REQUEST_FIELD_INTEGER:
        purple_request_field_int_set_value(f, num(values, id));
        break;
      case PURPLE_REQUEST_FIELD_BOOLEAN:
        purple_request_field_bool_set_value(f, num(values, id) != 0);
        break;
      case PURPLE_REQUEST_FIELD_CHOICE:
        purple_request_field_choice_set_value(f, num(values, id));
        break;
      case PURPLE_REQUEST_FIELD_LIST: {
        purple_request_field_list_clear_selected(f);
        JsonNode *n = json_object_get_member(values, id);
        if (JSON_NODE_HOLDS_ARRAY(n)) {
          JsonArray *a = json_node_get_array(n);
          for (guint j = 0; j < json_array_get_length(a); j++) {
            JsonNode *v = json_array_get_element(a, j);
            if (JSON_NODE_HOLDS_VALUE(v) &&
                json_node_get_value_type(v) == G_TYPE_STRING)
              purple_request_field_list_add_selected(f,
                                                     json_node_get_string(v));
          }
        } else
          purple_request_field_list_add_selected(f, str(values, id));
        break;
      }
      default:
        break;
      }
    }
  return purple_request_fields_all_required_filled(r->fields);
}
static void reply(JsonObject *o) {
  const char *id = str(o, "request");
  char *numeric = NULL;
  if (!*id) {
    numeric = g_strdup_printf("%d", num(o, "request"));
    id = numeric;
  }
  Request *r = g_hash_table_lookup(requests, id);
  g_free(numeric);
  if (!r) {
    error_event("Unknown request", NULL);
    return;
  }
  int selected = num(o, "action");
  JsonObject *values = obj(o, "values");
  if (r->type == PURPLE_REQUEST_ACTION) {
    if (selected < -1 || selected >= (int)r->callbacks->len) {
      error_event("Invalid action", r->account);
      return;
    }
  } else if (selected != -1 && selected != 0 && selected != 1) {
    error_event("Invalid action", r->account);
    return;
  }
  if (r->type == PURPLE_REQUEST_FIELDS && selected == 0 &&
      !set_fields(r, values)) {
    error_event("Required fields are missing", r->account);
    return;
  }
  /* Callbacks may close the request themselves: copy arguments first. */
  PurpleRequestType type = r->type;
  gpointer data = r->data;
  GCallback cb =
      type == PURPLE_REQUEST_ACTION
          ? (selected < 0
                 ? NULL
                 : (GCallback)g_ptr_array_index(r->callbacks, selected))
          : (selected == 0 ? r->ok : r->cancel);
  PurpleRequestFields *fields = r->fields;
  char *rid = g_strdup(r->id);
  char *value = g_strdup(str(values, "value"));
  int choice = num(values, "value");
  if (cb) {
    if (type == PURPLE_REQUEST_ACTION || type == PURPLE_REQUEST_CHOICE)
      ((PurpleRequestActionCb)cb)(data, type == PURPLE_REQUEST_ACTION ? selected
                                                                      : choice);
    else if (type == PURPLE_REQUEST_INPUT)
      ((PurpleRequestInputCb)cb)(data, selected == 0 ? value : NULL);
    else if (type == PURPLE_REQUEST_FIELDS)
      ((PurpleRequestFieldsCb)cb)(data, fields);
  }
  r = g_hash_table_lookup(requests, rid);
  if (r)
    purple_request_close(type, r);
  g_free(rid);
  g_free(value);
}
static JsonObject *option_json(PurpleAccountOption *op) {
  JsonObject *o = json_object_new();
  s(o, "key", purple_account_option_get_setting(op));
  s(o, "label", purple_account_option_get_text(op));
  b(o, "masked", FALSE);
  switch (purple_account_option_get_type(op)) {
  case PURPLE_PREF_BOOLEAN:
    s(o, "type", "bool");
    b(o, "default", purple_account_option_get_default_bool(op));
    break;
  case PURPLE_PREF_INT:
    s(o, "type", "int");
    i(o, "default", purple_account_option_get_default_int(op));
    break;
  case PURPLE_PREF_STRING:
    s(o, "type", "string");
    s(o, "default", purple_account_option_get_default_string(op));
    b(o, "masked", purple_account_option_get_masked(op));
    break;
  case PURPLE_PREF_STRING_LIST: {
    s(o, "type", "list");
    s(o, "default", purple_account_option_get_default_list_value(op));
    JsonArray *v = json_array_new();
    for (GList *l = purple_account_option_get_list(op); l; l = l->next) {
      PurpleKeyValuePair *pair = l->data;
      JsonObject *item = json_object_new();
      s(item, "label", pair->key);
      s(item, "value", pair->value);
      json_array_add_object_element(v, item);
    }
    json_object_set_array_member(o, "values", v);
    break;
  }
  default:
    s(o, "type", "string");
    s(o, "default", "");
    break;
  }
  return o;
}
/* Protocol icon names are provided by the PRPL, not derived from display names
 * or IDs (XMPP, for example, reports "jabber"). Search the prefix belonging to
 * the loaded libpurple as well as the normal XDG data directories. */
static void add_icon(JsonArray *icons, GHashTable *seen, const char *path,
                     int size) {
  if (!g_file_test(path, G_FILE_TEST_IS_REGULAR) ||
      g_hash_table_contains(seen, path))
    return;
  g_hash_table_add(seen, g_strdup(path));
  JsonObject *icon = json_object_new();
  s(icon, "path", path);
  i(icon, "size", size);
  json_array_add_object_element(icons, icon);
}
static void protocol_icons(JsonObject *item, PurplePluginProtocolInfo *info) {
  const char *name = info->list_icon ? info->list_icon(NULL, NULL) : NULL;
  JsonArray *icons = json_array_new();
  json_object_set_array_member(item, "icons", icons);
  if (!name || !*name || strspn(name, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.") != strlen(name))
    return;
  s(item, "iconName", name);
  GPtrArray *roots = g_ptr_array_new_with_free_func(g_free);
  const char *test_root = g_getenv("ADP_ICON_DATA_DIR");
  if (test_root && *test_root) g_ptr_array_add(roots, g_strdup(test_root));
  g_ptr_array_add(roots, g_strdup(g_get_user_data_dir()));
  Dl_info library;
  if (dladdr((void *)purple_core_get_version, &library) && library.dli_fname) {
    char *libdir = g_path_get_dirname(library.dli_fname);
    char *prefix = g_path_get_dirname(libdir);
    g_ptr_array_add(roots, g_build_filename(prefix, "share", NULL));
    g_free(prefix); g_free(libdir);
  }
  for (const char *const *dir = g_get_system_data_dirs(); *dir; dir++)
    g_ptr_array_add(roots, g_strdup(*dir));
  GHashTable *seen = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
  const int sizes[] = {16, 22, 24, 32, 48, 64, 96, 128, 256, 512, 0};
  for (guint r = 0; r < roots->len; r++) {
    const char *root = g_ptr_array_index(roots, r);
    for (guint z = 0; z < G_N_ELEMENTS(sizes); z++) {
      int size = sizes[z];
      char *folder = size ? g_strdup_printf("%d", size) : g_strdup("scalable");
      char *theme_size = size ? g_strdup_printf("%dx%d", size, size) : g_strdup("scalable");
      const char *extensions[] = {"png", "svg", "pdf", "icns"};
      for (guint e = 0; e < G_N_ELEMENTS(extensions); e++) {
        char *filename = g_strdup_printf("%s.%s", name, extensions[e]);
        const char *families[] = {"pidgin", "purple"};
        for (guint f = 0; f < G_N_ELEMENTS(families); f++) {
          char *path = g_build_filename(root, "pixmaps", families[f], "protocols", folder, filename, NULL);
          add_icon(icons, seen, path, size); g_free(path);
        }
        const char *prefixes[] = {"", "pidgin-", "im-"};
        for (guint p = 0; p < G_N_ELEMENTS(prefixes); p++) {
          char *themed = g_strconcat(prefixes[p], filename, NULL);
          char *path = g_build_filename(root, "icons", "hicolor", theme_size, "apps", themed, NULL);
          add_icon(icons, seen, path, size); g_free(path); g_free(themed);
        }
        g_free(filename);
      }
      g_free(folder); g_free(theme_size);
    }
  }
  g_hash_table_destroy(seen);
  g_ptr_array_free(roots, TRUE);
}
static void discover(void) {
  JsonObject *o = event("protocols", NULL);
  s(o, "version", ADP_VERSION);
  s(o, "backendVersion", ADP_VERSION);
  s(o, "purpleVersion", purple_core_get_version());
  i(o, "ipcVersion", 1);
  JsonArray *array = json_array_new();
  for (GList *l = purple_plugins_get_protocols(); l; l = l->next) {
    PurplePlugin *p = l->data;
    PurplePluginProtocolInfo *info = PURPLE_PLUGIN_PROTOCOL_INFO(p);
    JsonObject *item = json_object_new();
    s(item, "id", p->info->id);
    s(item, "name", p->info->name);
    s(item, "path", p->path);
    protocol_icons(item, info);
    b(item, "noPassword", (info->options & OPT_PROTO_NO_PASSWORD) != 0);
    b(item, "passwordOptional",
      (info->options & OPT_PROTO_PASSWORD_OPTIONAL) != 0);
    b(item, "chat", info->join_chat && info->chat_send);
    JsonArray *opts = json_array_new();
    for (GList *op = info->protocol_options; op; op = op->next)
      json_array_add_object_element(opts, option_json(op->data));
    json_object_set_array_member(item, "options", opts);
    json_array_add_object_element(array, item);
  }
  json_object_set_array_member(o, "protocols", array);
  emit(o);
}
/* libpurple 2 exposes account->settings but not a type-query accessor.
 * PurpleAccountSetting starts with PurplePrefType in libpurple 2.10--2.14.
 * Read only that discriminator, then use public typed accessors for values.
 * This intentionally supports libpurple 2, not the incompatible libpurple 3
 * ABI.
 */
static void account_updated(PurpleAccount *a) {
  if (!*aid(a))
    return;
  JsonObject *options = json_object_new();
  /* Declared defaults reset removed settings in the frontend, including tokens.
   */
  PurplePlugin *plugin = purple_find_prpl(purple_account_get_protocol_id(a));
  PurplePluginProtocolInfo *protocol =
      plugin ? PURPLE_PLUGIN_PROTOCOL_INFO(plugin) : NULL;
  for (GList *l = protocol ? protocol->protocol_options : NULL; l;
       l = l->next) {
    PurpleAccountOption *option = l->data;
    const char *key = purple_account_option_get_setting(option);
    switch (purple_account_option_get_type(option)) {
    case PURPLE_PREF_BOOLEAN:
      b(options, key, purple_account_option_get_default_bool(option));
      break;
    case PURPLE_PREF_INT:
      i(options, key, purple_account_option_get_default_int(option));
      break;
    case PURPLE_PREF_STRING:
      s(options, key, purple_account_option_get_default_string(option));
      break;
    case PURPLE_PREF_STRING_LIST:
      s(options, key, purple_account_option_get_default_list_value(option));
      break;
    default:
      break;
    }
  }
  GHashTableIter iter;
  gpointer key, value;
  g_hash_table_iter_init(&iter, a->settings);
  while (g_hash_table_iter_next(&iter, &key, &value)) {
    PurplePrefType type;
    memcpy(&type, value, sizeof type);
    switch (type) {
    case PURPLE_PREF_BOOLEAN:
      b(options, key, purple_account_get_bool(a, key, FALSE));
      break;
    case PURPLE_PREF_INT:
      i(options, key, purple_account_get_int(a, key, 0));
      break;
    case PURPLE_PREF_STRING: {
      const char *text = purple_account_get_string(a, key, NULL);
      /* NULL invalidates a token without necessarily removing its table entry.
       */
      if (text)
        s(options, key, text);
      break;
    }
    default:
      break;
    }
  }
  JsonObject *snapshot = json_object_new();
  s(snapshot, "password", purple_account_get_password(a));
  json_object_set_object_member(snapshot, "options", json_object_ref(options));
  JsonNode *next = json_node_new(JSON_NODE_OBJECT);
  json_node_take_object(next, snapshot);
  JsonNode *previous = g_hash_table_lookup(snapshots, a);
  if (previous && json_node_equal(previous, next)) {
    json_node_free(next);
    json_object_unref(options);
    return;
  }
  JsonObject *o = event("accountUpdated", a);
  b(o, "optionsComplete", TRUE);
  if (!previous || strcmp(str(json_node_get_object(previous), "password"),
                          str(snapshot, "password")))
    s(o, "password", str(snapshot, "password"));
  json_object_set_object_member(o, "options", options);
  g_hash_table_replace(snapshots, a, next);
  emit(o);
}
static gboolean update_accounts(gpointer unused) {
  (void)unused;
  GHashTableIter iter;
  gpointer key, value;
  g_hash_table_iter_init(&iter, accounts);
  while (g_hash_table_iter_next(&iter, &key, &value))
    account_updated(value);
  return TRUE;
}
static gboolean set_status(PurpleAccount *a, const char *name,
                           const char *message) {
  PurpleStatusPrimitive primitive = PURPLE_STATUS_AVAILABLE;
  if (!strcmp(name, "offline"))
    primitive = PURPLE_STATUS_OFFLINE;
  else if (!strcmp(name, "away"))
    primitive = PURPLE_STATUS_AWAY;
  else if (!strcmp(name, "invisible"))
    primitive = PURPLE_STATUS_INVISIBLE;
  else if (!strcmp(name, "dnd") || !strcmp(name, "unavailable"))
    primitive = PURPLE_STATUS_UNAVAILABLE;
  else if (!strcmp(name, "extended_away"))
    primitive = PURPLE_STATUS_EXTENDED_AWAY;
  PurpleStatusType *type = NULL;
  for (GList *l = purple_account_get_status_types(a); l; l = l->next) {
    PurpleStatusType *t = l->data;
    if (!strcmp(purple_status_type_get_id(t), name)) {
      type = t;
      break;
    }
    if (!type && purple_status_type_get_primitive(t) == primitive)
      type = t;
  }
  if (!type) {
    error_event("Protocol does not support requested status", a);
    return FALSE;
  }
  purple_account_set_status(a, purple_status_type_get_id(type), TRUE, "message",
                            message, NULL);
  return TRUE;
}
/* Preserve opaque protocol settings such as refresh tokens and message cursors.
 */
static void apply_options(PurpleAccount *a, JsonObject *options) {
  if (!options)
    return;
  PurplePlugin *plugin = purple_find_prpl(purple_account_get_protocol_id(a));
  PurplePluginProtocolInfo *protocol =
      plugin ? PURPLE_PLUGIN_PROTOCOL_INFO(plugin) : NULL;
  GList *keys = json_object_get_members(options);
  for (GList *l = keys; l; l = l->next) {
    const char *key = l->data;
    JsonNode *value = json_object_get_member(options, key);
    if (!JSON_NODE_HOLDS_VALUE(value))
      continue;
    GType type = json_node_get_value_type(value);
    gboolean known = FALSE;
    for (GList *op = protocol ? protocol->protocol_options : NULL; op;
         op = op->next) {
      PurpleAccountOption *option = op->data;
      if (strcmp(key, purple_account_option_get_setting(option)))
        continue;
      known = TRUE;
      switch (purple_account_option_get_type(option)) {
      case PURPLE_PREF_BOOLEAN:
        if (type == G_TYPE_BOOLEAN)
          purple_account_set_bool(a, key, json_node_get_boolean(value));
        break;
      case PURPLE_PREF_INT:
        if (type == G_TYPE_INT64 || type == G_TYPE_INT || type == G_TYPE_LONG)
          purple_account_set_int(a, key, (int)json_node_get_int(value));
        break;
      case PURPLE_PREF_STRING:
      case PURPLE_PREF_STRING_LIST:
        if (type == G_TYPE_STRING)
          purple_account_set_string(a, key, json_node_get_string(value));
        break;
      default:
        break;
      }
      break;
    }
    if (known)
      continue;
    if (type == G_TYPE_STRING)
      purple_account_set_string(a, key, json_node_get_string(value));
    else if (type == G_TYPE_BOOLEAN)
      purple_account_set_bool(a, key, json_node_get_boolean(value));
    else if (type == G_TYPE_INT64 || type == G_TYPE_INT || type == G_TYPE_LONG)
      purple_account_set_int(a, key, (int)json_node_get_int(value));
  }
  g_list_free(keys);
}
static void connect_failed(const char *id, const char *message, int reason) {
  JsonObject *o = event("disconnected", NULL);
  s(o, "account", id);
  s(o, "error", message);
  i(o, "reason", reason);
  emit(o);
}
static void command(JsonObject *o) {
  const char *cmd = str(o, "command"), *id = str(o, "account");
  if (!strcmp(cmd, "discover")) {
    discover();
    return;
  }
  if (!strcmp(cmd, "reply")) {
    reply(o);
    return;
  }
  PurpleAccount *a = g_hash_table_lookup(accounts, id);
  if (!strcmp(cmd, "connect")) {
    if (!*id || !*str(o, "username") || !purple_find_prpl(str(o, "protocol"))) {
      connect_failed(id, "Invalid account or protocol",
                     PURPLE_CONNECTION_ERROR_INVALID_SETTINGS);
      return;
    }
    if (a) {
      purple_account_set_enabled(a, UI, FALSE);
      if (!purple_account_is_disconnected(a))
        purple_account_disconnect(a);
      if (strcmp(purple_account_get_protocol_id(a), str(o, "protocol")) ||
          strcmp(purple_account_get_username(a), str(o, "username"))) {
        connect_failed(id,
                       "Account identity changed; use a new account identifier",
                       PURPLE_CONNECTION_ERROR_INVALID_SETTINGS);
        return;
      }
    } else {
      a = purple_account_new(str(o, "username"), str(o, "protocol"));
      a->ui_data = g_strdup(id);
      g_hash_table_insert(accounts, g_strdup(id),
                          a); /* Do not add to persistent accounts.xml. */
    }
    purple_account_set_remember_password(a, FALSE);
    purple_account_set_password(a, str(o, "password"));
    apply_options(a, obj(o, "options"));
    const char *status = str(o, "status");
    if (!*status)
      status = "available";
    if (!set_status(a, status, str(o, "statusMessage"))) {
      connect_failed(id, "Protocol does not support requested status",
                     PURPLE_CONNECTION_ERROR_INVALID_SETTINGS);
    } else if (!purple_presence_is_online(purple_account_get_presence(a))) {
      connect_failed(id, "Requested offline status", 0);
    } else {
      purple_account_set_enabled(a, UI, TRUE);
    }
    return;
  }
  if (!a) {
    error_event("Unknown account", NULL);
    return;
  }
  PurpleConnection *gc = purple_account_get_connection(a);
  if (!strcmp(cmd, "disconnect")) {
    account_updated(a);
    purple_account_set_enabled(a, UI, FALSE);
    if (gc)
      if (!purple_account_is_disconnected(a))
        purple_account_disconnect(a);
    return;
  }
  if (!strcmp(cmd, "status")) {
    set_status(a, str(o, "status"), str(o, "statusMessage"));
    return;
  }
  if (!gc || !PURPLE_CONNECTION_IS_CONNECTED(gc)) {
    error_event("Account is not connected", a);
    return;
  }
  if (!strcmp(cmd, "chatInfo")) {
    chat_info(gc);
    return;
  }
  if (!strcmp(cmd, "sendIM")) {
    if (!*str(o, "to")) {
      error_event("Missing recipient", a);
      return;
    }
    PurpleConversation *c = purple_find_conversation_with_account(
        PURPLE_CONV_TYPE_IM, str(o, "to"), a);
    if (!c)
      c = purple_conversation_new(PURPLE_CONV_TYPE_IM, a, str(o, "to"));
    purple_conv_im_send(PURPLE_CONV_IM(c), str(o, "message"));
  } else if (!strcmp(cmd, "typing")) {
    serv_send_typing(gc, str(o, "to"),
                     (PurpleTypingState)CLAMP(num(o, "state"), 0, 2));
  } else if (!strcmp(cmd, "addBuddy")) {
    const char *name = str(o, "name");
    if (!*name)
      name = str(o, "to");
    if (!*name) {
      error_event("Missing buddy name", a);
      return;
    }
    PurpleBuddy *buddy = purple_find_buddy(a, name);
    if (!buddy) {
      const char *group = str(o, "group");
      if (!*group)
        group = "Buddies";
      PurpleGroup *g = purple_find_group(group);
      if (!g) {
        g = purple_group_new(group);
        purple_blist_add_group(g, NULL);
      }
      buddy = purple_buddy_new(a, name, str(o, "alias"));
      purple_blist_add_buddy(buddy, NULL, g, NULL);
    }
    purple_account_add_buddy(a, buddy);
  } else if (!strcmp(cmd, "removeBuddy")) {
    const char *name = str(o, "name");
    if (!*name)
      name = str(o, "to");
    PurpleBuddy *buddy = purple_find_buddy(a, name);
    if (buddy) {
      purple_account_remove_buddy(a, buddy, purple_buddy_get_group(buddy));
      purple_blist_remove_buddy(buddy);
    }
  } else if (!strcmp(cmd, "joinChat")) {
    JsonObject *components = obj(o, "components");
    if (!components) {
      error_event("Missing chat components", a);
      return;
    }
    GHashTable *table =
        g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
    GList *keys = json_object_get_members(components);
    for (GList *l = keys; l; l = l->next)
      g_hash_table_insert(table, g_strdup(l->data),
                          g_strdup(str(components, l->data)));
    g_list_free(keys);
    serv_join_chat(gc, table);
    g_hash_table_destroy(table);
  } else if (!strcmp(cmd, "sendChat")) {
    serv_chat_send(gc, num(o, "chat"), str(o, "message"), PURPLE_MESSAGE_SEND);
  } else if (!strcmp(cmd, "leaveChat")) {
    serv_chat_leave(gc, num(o, "chat"));
  } else
    error_event("Unknown command", a);
}
/* Byte-oriented nonblocking input avoids a partial line blocking the GLib loop.
 */
static GString *input;
static gboolean stdin_cb(GIOChannel *channel, GIOCondition cond,
                         gpointer unused) {
  (void)channel;
  (void)unused;
  char buffer[8192];
  ssize_t count;
  while ((count = read(STDIN_FILENO, buffer, sizeof buffer)) > 0) {
    g_string_append_len(input, buffer, count);
    if (input->len > 4 * 1024 * 1024) {
      error_event("IPC line exceeds limit", NULL);
      stopping = TRUE;
      g_main_loop_quit(loop);
      return FALSE;
    }
    char *newline;
    while ((newline = memchr(input->str, '\n', input->len))) {
      gsize length = newline - input->str;
      JsonParser *p = json_parser_new();
      if (json_parser_load_from_data(p, input->str, length, NULL) &&
          JSON_NODE_HOLDS_OBJECT(json_parser_get_root(p)))
        command(json_node_get_object(json_parser_get_root(p)));
      else
        error_event("Invalid JSON command", NULL);
      g_object_unref(p);
      memset(input->str, 0, length);
      g_string_erase(input, 0, length + 1);
    }
  }
  if (count == 0 || (cond & (G_IO_HUP | G_IO_ERR | G_IO_NVAL))) {
    stopping = TRUE;
    g_main_loop_quit(loop);
    return FALSE;
  }
  return TRUE;
}
static PurpleDebugUiOps debugops = {.print = debug_print};
static void ui_init(void) {
  purple_connections_set_ui_ops(&cops);
  purple_conversations_set_ui_ops(&convops);
  purple_blist_set_ui_ops(&blistops);
  purple_request_set_ui_ops(&requestops);
  purple_notify_set_ui_ops(&notifyops);
}
static PurpleCoreUiOps coreops = {.ui_init = ui_init};
int main(void) {
  umask(0077);
  signal(SIGPIPE, SIG_IGN);
  ipc_fd = dup(STDOUT_FILENO);
  if (ipc_fd < 0)
    return 1; /* Native modules cannot corrupt IPC through printf(). */
  fcntl(ipc_fd, F_SETFD, FD_CLOEXEC);
  dup2(STDERR_FILENO, STDOUT_FILENO);
  loop = g_main_loop_new(NULL, FALSE);
  accounts = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
  requests = g_hash_table_new(g_str_hash, g_str_equal);
  snapshots = g_hash_table_new_full(g_direct_hash, g_direct_equal, NULL,
                                    (GDestroyNotify)json_node_free);
  failures = g_hash_table_new_full(g_direct_hash, g_direct_equal, NULL,
                                   (GDestroyNotify)json_object_unref);
  char *profile =
      g_build_filename(g_get_home_dir(), "Library", "Application Support",
                       "Adium DynamicPurple", "backend", NULL);
  const char *test_profile = g_getenv("ADP_BACKEND_PROFILE");
  if (test_profile && *test_profile) {
    g_free(profile);
    profile = g_strdup(test_profile);
  }
  if (g_mkdir_with_parents(profile, 0700) || chmod(profile, 0700)) {
    JsonObject *fatal = event("backendError", NULL);
    s(fatal, "message", "Cannot create private backend profile");
    emit(fatal);
    return 1;
  }
  purple_util_set_user_dir(profile);
  g_free(profile);
  purple_debug_set_ui_ops(&debugops);
  purple_debug_set_enabled(FALSE);
  purple_core_set_ui_ops(&coreops);
  purple_eventloop_set_ui_ops(&eloop);
  char *plugins =
      g_build_filename(g_get_home_dir(), ".purple", "plugins", NULL);
  purple_plugins_add_search_path(plugins);
  g_free(plugins);
  const char *test_plugins = g_getenv("ADP_BACKEND_PLUGIN_PATH");
  if (test_plugins && *test_plugins)
    purple_plugins_add_search_path(test_plugins);
  if (!purple_core_init(UI)) {
    JsonObject *fatal = event("backendError", NULL);
    s(fatal, "message", "libpurple initialization failed");
    emit(fatal);
    return 1;
  }
  purple_set_blist(purple_blist_new());
  for (GList *l = purple_accounts_get_all(); l; l = l->next)
    purple_account_set_enabled(l->data, UI, FALSE);
  while (purple_accounts_get_all())
    purple_accounts_delete(purple_accounts_get_all()->data);
  /* Never restore saved accounts or saved online status. */
  purple_prefs_set_bool("/purple/logging/log_ims", FALSE);
  purple_prefs_set_bool("/purple/logging/log_chats", FALSE);
  purple_prefs_set_bool("/purple/logging/log_system", FALSE);
  purple_plugins_probe("so");
  purple_plugins_probe("dylib");
  purple_signal_connect(purple_conversations_get_handle(), "chat-joined",
                        &coreops, PURPLE_CALLBACK(chat_joined), NULL);
  purple_signal_connect(purple_conversations_get_handle(), "chat-left",
                        &coreops, PURPLE_CALLBACK(chat_left), NULL);
  purple_signal_connect(purple_conversations_get_handle(), "buddy-typing",
                        &coreops, PURPLE_CALLBACK(typing_event),
                        GINT_TO_POINTER(PURPLE_TYPING));
  purple_signal_connect(purple_conversations_get_handle(), "buddy-typed",
                        &coreops, PURPLE_CALLBACK(typing_event),
                        GINT_TO_POINTER(PURPLE_TYPED));
  purple_signal_connect(
      purple_conversations_get_handle(), "buddy-typing-stopped", &coreops,
      PURPLE_CALLBACK(typing_event), GINT_TO_POINTER(PURPLE_NOT_TYPING));
  g_timeout_add_seconds(2, update_accounts, NULL);
  input = g_string_new(NULL);
  fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK);
  GIOChannel *channel = g_io_channel_unix_new(STDIN_FILENO);
  g_io_add_watch(channel, G_IO_IN | G_IO_HUP | G_IO_ERR, stdin_cb, NULL);
  g_io_channel_unref(channel);
  discover();
  g_main_loop_run(loop);
  update_accounts(NULL);
  GHashTableIter it;
  gpointer key, value;
  g_hash_table_iter_init(&it, accounts);
  while (g_hash_table_iter_next(&it, &key, &value)) {
    PurpleAccount *a = value;
    purple_account_set_enabled(a, UI, FALSE);
    if (!purple_account_is_disconnected(a))
      purple_account_disconnect(a);
    char *identifier = a->ui_data;
    purple_account_destroy(a);
    g_free(identifier);
  }
  purple_core_quit();
  g_string_free(input, TRUE);
  g_hash_table_destroy(accounts);
  g_hash_table_destroy(failures);
  g_hash_table_destroy(snapshots);
  g_hash_table_destroy(requests);
  g_main_loop_unref(loop);
  close(ipc_fd);
  return 0;
}
