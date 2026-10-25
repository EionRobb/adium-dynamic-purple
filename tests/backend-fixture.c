/* GPL-3.0-or-later. No-network protocol exercising real libpurple callbacks. */
#include <purple.h>
#include <unistd.h>
typedef struct {
  PurpleAccount *account;
  int pipefd[2];
  guint timer, input;
} Session;
static const char *icon(PurpleAccount *a, PurpleBuddy *b) {
  (void)a;
  (void)b;
  return "test";
}
static GList *statuses(PurpleAccount *a) {
  (void)a;
  GList *l = NULL;
  l = g_list_append(l, purple_status_type_new_full(PURPLE_STATUS_OFFLINE,
                                                   "offline", "Offline", TRUE,
                                                   TRUE, FALSE));
  l = g_list_append(l, purple_status_type_new_with_attrs(
                           PURPLE_STATUS_AVAILABLE, "available", "Online", TRUE,
                           TRUE, FALSE, "message", "Message",
                           purple_value_new(PURPLE_TYPE_STRING), NULL));
  l = g_list_append(l, purple_status_type_new_with_attrs(
                           PURPLE_STATUS_AWAY, "away", "Away", TRUE, TRUE,
                           FALSE, "message", "Message",
                           purple_value_new(PURPLE_TYPE_STRING), NULL));
  return l;
}
static gboolean login_done(gpointer data) {
  Session *session = data;
  session->timer = 0;
  (void)write(session->pipefd[1], "x", 1);
  return FALSE;
}
static void login_input(gpointer data, gint fd,
                        PurpleInputCondition condition) {
  Session *session = data;
  char byte;
  (void)condition;
  (void)read(fd, &byte, 1);
  purple_input_remove(session->input);
  session->input = 0;
  purple_connection_set_state(purple_account_get_connection(session->account),
                              PURPLE_CONNECTED);
}
static void login(PurpleAccount *a) {
  Session *session = g_new0(Session, 1);
  session->account = a;
  g_assert(pipe(session->pipefd) == 0);
  purple_connection_set_protocol_data(purple_account_get_connection(a),
                                      session);
  session->input = purple_input_add(session->pipefd[0], PURPLE_INPUT_READ,
                                    login_input, session);
  session->timer = purple_timeout_add(20, login_done, session);
}
static void close_connection(PurpleConnection *gc) {
  purple_request_close_with_handle(gc);
  Session *session = purple_connection_get_protocol_data(gc);
  if (session) {
    if (session->timer)
      purple_timeout_remove(session->timer);
    if (session->input)
      purple_input_remove(session->input);
    close(session->pipefd[0]);
    close(session->pipefd[1]);
    g_free(session);
    purple_connection_set_protocol_data(gc, NULL);
  }
}
static void echo(PurpleConnection *gc, const char *text) {
  serv_got_im(gc, "fixture", text, PURPLE_MESSAGE_RECV, time(NULL));
}
static void input_reply(void *data, const char *value) {
  echo(data, value ? value : "cancelled");
}
static void action_reply(void *data, int which) {
  char *m = g_strdup_printf("action:%d", which);
  echo(data, m);
  g_free(m);
}
static void fields_reply(void *data, PurpleRequestFields *f) {
  char *m = g_strdup_printf("fields:%s:%d:%d",
                            purple_request_fields_get_string(f, "token"),
                            purple_request_fields_get_integer(f, "number"),
                            purple_request_fields_get_bool(f, "remember"));
  echo(data, m);
  g_free(m);
}
static int send_im(PurpleConnection *gc, const char *who, const char *m,
                   PurpleMessageFlags flags) {
  (void)flags;
  PurpleAccount *a = purple_connection_get_account(gc);
  if (!strcmp(who, "remote-peer")) {
    PurpleConversation *conversation =
        purple_find_conversation_with_account(PURPLE_CONV_TYPE_IM, who, a);
    purple_conv_im_write(
        PURPLE_CONV_IM(conversation), purple_account_get_username(a), m,
        PURPLE_MESSAGE_SEND | PURPLE_MESSAGE_REMOTE_SEND, time(NULL));
    return 0;
  }
  if (!strcmp(who, "input"))
    purple_request_input(gc, "OAuth", "Enter code", NULL, "", FALSE, TRUE, NULL,
                         "OK", G_CALLBACK(input_reply), "Cancel",
                         G_CALLBACK(input_reply), a, NULL, NULL, gc);
  else if (!strcmp(who, "action"))
    purple_request_action(gc, "Action", "Choose", NULL, 0, a, NULL, NULL, gc, 2,
                          "First", G_CALLBACK(action_reply), "Second",
                          G_CALLBACK(action_reply));
  else if (!strcmp(who, "choice"))
    purple_request_choice(gc, "Choice", "Choose", NULL, 42, "OK",
                          G_CALLBACK(action_reply), "Cancel",
                          G_CALLBACK(action_reply), a, NULL, NULL, gc, "Alpha",
                          42, "Beta", 77, NULL);
  else if (!strcmp(who, "fields")) {
    PurpleRequestFields *fields = purple_request_fields_new();
    PurpleRequestFieldGroup *group = purple_request_field_group_new(NULL);
    purple_request_fields_add_group(fields, group);
    PurpleRequestField *f =
        purple_request_field_string_new("token", "Token", "", FALSE);
    purple_request_field_set_required(f, TRUE);
    purple_request_field_string_set_masked(f, TRUE);
    purple_request_field_group_add_field(group, f);
    purple_request_field_group_add_field(
        group, purple_request_field_int_new("number", "Number", 7));
    purple_request_field_group_add_field(
        group, purple_request_field_bool_new("remember", "Remember", FALSE));
    purple_request_fields(gc, "Fields", "Complete", NULL, fields, "OK",
                          G_CALLBACK(fields_reply), "Cancel", NULL, a, NULL,
                          NULL, gc);
  } else {
    purple_account_set_string(a, "token", m);
    if (!strcmp(who, "refresh")) {
      purple_account_set_password(a, "synthetic-refreshed-token");
      purple_account_set_remember_password(a, TRUE);
      purple_account_set_string(a, "opaque-cursor", "cursor-17");
      purple_account_set_int(a, "opaque-int", 19);
      purple_account_set_bool(a, "opaque-bool", TRUE);
    }
    if (!strcmp(who, "clear")) {
      purple_account_set_string(a, "token", NULL);
      purple_account_set_string(a, "opaque-cursor", NULL);
      purple_account_remove_setting(a, "opaque-int");
    }
    echo(gc, m);
  }
  return 1;
}
static void set_status(PurpleAccount *a, PurpleStatus *s) {
  (void)a;
  (void)s;
}
static void join(PurpleConnection *gc, GHashTable *components) {
  const char *name = g_hash_table_lookup(components, "room");
  PurpleConversation *c = serv_got_joined_chat(gc, 17, name ? name : "test");
  purple_conv_chat_add_user(PURPLE_CONV_CHAT(c), "fixture", "Alias",
                            PURPLE_CBFLAGS_NONE, FALSE);
}
static int chat_send(PurpleConnection *gc, int id, const char *m,
                     PurpleMessageFlags flags) {
  (void)flags;
  serv_got_chat_in(gc, id, "fixture", PURPLE_MESSAGE_RECV, m, time(NULL));
  return 0;
}
static void chat_leave(PurpleConnection *gc, int id) {
  serv_got_chat_left(gc, id);
}
static GList *chat_info(PurpleConnection *gc) {
  (void)gc;
  struct proto_chat_entry *entry = g_new0(struct proto_chat_entry, 1);
  entry->identifier = "room";
  entry->label = "Room Identifier";
  entry->required = TRUE;
  return g_list_append(NULL, entry);
}
static GHashTable *chat_defaults(PurpleConnection *gc, const char *name) {
  (void)gc;
  (void)name;
  GHashTable *defaults =
      g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
  g_hash_table_insert(defaults, g_strdup("room"), g_strdup("Synthetic Room"));
  return defaults;
}
static PurplePluginProtocolInfo protocol = {
    .options = OPT_PROTO_NO_PASSWORD,
    .chat_info = chat_info,
    .chat_info_defaults = chat_defaults,
    .list_icon = icon,
    .status_types = statuses,
    .login = login,
    .close = close_connection,
    .send_im = send_im,
    .set_status = set_status,
    .join_chat = join,
    .chat_send = chat_send,
    .chat_leave = chat_leave,
    .struct_size = sizeof(PurplePluginProtocolInfo)};
static PurplePluginInfo info = {.magic = PURPLE_PLUGIN_MAGIC,
                                .major_version = PURPLE_MAJOR_VERSION,
                                .minor_version = PURPLE_MINOR_VERSION,
                                .type = PURPLE_PLUGIN_PROTOCOL,
                                .id = "prpl-adp-backend-fixture",
                                .name = "Backend Fixture",
                                .version = "1",
                                .summary = "No-network IPC fixture",
                                .description = "No-network IPC fixture",
                                .author = "Tests",
                                .homepage = "",
                                .extra_info = &protocol};
static void init(PurplePlugin *p) {
  (void)p;
  protocol.protocol_options = g_list_append(
      NULL, purple_account_option_string_new("Token", "token", ""));
  purple_account_option_set_masked(protocol.protocol_options->data, TRUE);
  protocol.protocol_options =
      g_list_append(protocol.protocol_options,
                    purple_account_option_bool_new("Boolean", "boolean", TRUE));
  protocol.protocol_options =
      g_list_append(protocol.protocol_options,
                    purple_account_option_int_new("Integer", "integer", 9));
}
PURPLE_INIT_PLUGIN(adp_backend_fixture, init, info)
