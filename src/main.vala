using Gtk;
using GLib;

const string APP_ID = "org.mate.fprint";
const string TITLE_MARKUP = "<span size=\"x-large\" weight=\"bold\">%s</span>";

struct FingerInfo {
    public string id;
    public string label;

    public FingerInfo (string id, string label) {
        this.id = id;
        this.label = label;
    }
}

class FprintClient : Object {
    // Calls that may show a polkit password prompt must wait for the user.
    private const int AUTH_TIMEOUT = int.MAX;

    private DBusProxy? manager;
    private DBusProxy? device;
    private ulong signal_id;
    private bool claimed;

    public string connect_device () throws Error {
        close ();
        manager = new DBusProxy.for_bus_sync (
            BusType.SYSTEM,
            DBusProxyFlags.NONE,
            null,
            "net.reactivated.Fprint",
            "/net/reactivated/Fprint/Manager",
            "net.reactivated.Fprint.Manager",
            null
        );
        Variant reply = manager.call_sync (
            "GetDevices", null, DBusCallFlags.NONE, 5000, null
        );
        Variant paths = reply.get_child_value (0);
        if (paths.n_children () == 0) {
            return "";
        }
        string path = paths.get_child_value (0).get_string ();
        device = new DBusProxy.for_bus_sync (
            BusType.SYSTEM,
            DBusProxyFlags.NONE,
            null,
            "net.reactivated.Fprint",
            path,
            "net.reactivated.Fprint.Device",
            null
        );
        Variant? name = device.get_cached_property ("name");
        return name != null ? name.get_string () : _("Fingerprint reader");
    }

    public void claim () throws Error {
        if (device == null || claimed) {
            return;
        }
        try {
            device.call_sync (
                "Claim",
                new Variant ("(s)", Environment.get_user_name ()),
                DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION,
                AUTH_TIMEOUT,
                null
            );
            claimed = true;
        } catch (Error error) {
            if (!error.message.contains ("AlreadyInUse")) {
                throw error;
            }
        }
    }

    public HashTable<string, string> list_enrolled () throws Error {
        var enrolled = new HashTable<string, string> (str_hash, str_equal);
        if (device == null) {
            return enrolled;
        }
        try {
            Variant reply = device.call_sync (
                "ListEnrolledFingers",
                new Variant ("(s)", Environment.get_user_name ()),
                DBusCallFlags.NONE,
                5000,
                null
            );
            Variant names = reply.get_child_value (0);
            for (size_t index = 0; index < names.n_children (); index++) {
                string finger = names.get_child_value (index).get_string ();
                enrolled.insert (finger, finger);
            }
        } catch (Error error) {
            if (!error.message.contains ("NoEnrolledPrints")) {
                throw error;
            }
        }
        return enrolled;
    }

    public int get_enroll_stages () {
        if (device == null) {
            return 5;
        }
        Variant? stages = device.get_cached_property ("num-enroll-stages");
        if (stages == null) {
            return 5;
        }
        return int.max (1, stages.get_int32 ());
    }

    public void start_enrollment (string finger, owned EnrollCallback callback) throws Error {
        claim ();
        disconnect_signal ();
        signal_id = device.g_signal.connect ((sender, name, parameters) => {
            if (name == "EnrollStatus") {
                string status;
                bool done;
                parameters.get ("(sb)", out status, out done);
                callback (status, done);
            }
        });
        try {
            device.call_sync (
                "EnrollStart",
                new Variant ("(s)", finger),
                DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION,
                AUTH_TIMEOUT,
                null
            );
        } catch (Error error) {
            disconnect_signal ();
            throw error;
        }
    }

    public void stop_enrollment () throws Error {
        disconnect_signal ();
        if (device == null) {
            return;
        }
        try {
            device.call_sync ("EnrollStop", null, DBusCallFlags.NONE, 3000, null);
        } catch (Error error) {
            if (!error.message.contains ("NoActionInProgress")) {
                throw error;
            }
        }
    }

    public void delete_finger (string finger) throws Error {
        claim ();
        device.call_sync (
            "DeleteEnrolledFinger",
            new Variant ("(s)", finger),
            DBusCallFlags.ALLOW_INTERACTIVE_AUTHORIZATION,
            AUTH_TIMEOUT,
            null
        );
    }

    public void close () {
        disconnect_signal ();
        if (device != null && claimed) {
            try {
                device.call_sync ("Release", null, DBusCallFlags.NONE, 3000, null);
            } catch (Error error) {
            }
        }
        claimed = false;
        device = null;
        manager = null;
    }

    private void disconnect_signal () {
        if (device != null && signal_id != 0) {
            device.disconnect (signal_id);
        }
        signal_id = 0;
    }

    public delegate void EnrollCallback (string status, bool done);
}

class Fingerprint : DrawingArea {
    private double progress;
    private bool success;

    public Fingerprint (int size = 96) {
        set_size_request (size, size);
        draw.connect (draw_print);
    }

    public void set_progress (double value, bool success = false) {
        progress = value.clamp (0.0, 1.0);
        this.success = success;
        queue_draw ();
    }

    private bool draw_print (Cairo.Context cr) {
        double cx = get_allocated_width () / 2.0;
        double cy = get_allocated_height () / 2.0 + 5;
        double scale = int.min (get_allocated_width (), get_allocated_height ()) / 110.0;
        Gdk.RGBA color;
        if (!get_style_context ().lookup_color ("theme_fg_color", out color)) {
            color = get_style_context ().get_color (get_state_flags ());
        }
        if (success && !get_style_context ().lookup_color ("theme_selected_bg_color", out color)) {
            color = Gdk.RGBA ();
            color.parse ("#2e8b3c");
        }
        double[] radii = { 10, 19, 28, 37, 46 };
        int active = (int) (progress * 5.0 + 0.999);
        cr.set_line_cap (Cairo.LineCap.ROUND);
        cr.set_line_width (double.max (2.0, 3.2 * scale));
        for (int i = 0; i < radii.length; i++) {
            double alpha = i < active ? 1.0 : 0.28;
            cr.set_source_rgba (color.red, color.green, color.blue, alpha);
            cr.arc (cx, cy, radii[i] * scale, 0, 6.283185307179586);
            cr.stroke ();
        }
        return false;
    }
}

class MainWindow : ApplicationWindow {
    private FprintClient client;
    private Stack stack;
    private Grid finger_grid;
    private Label device_label;
    private Fingerprint detail_print;
    private Label detail_title;
    private Label detail_status;
    private Button remove_button;
    private Button enroll_button;
    private Fingerprint enroll_print;
    private Label enroll_title;
    private Label enroll_instruction;
    private Label enroll_status;
    private ProgressBar progress_bar;
    private Button cancel_button;
    private Gtk.MenuItem disable_item;
    private HashTable<string, string> enrolled;
    private string current_finger;
    private string current_label;
    private int scans;
    private int stages;
    private bool demo;

    private FingerInfo[] fingers = {
        FingerInfo ("left-thumb", _("Left thumb")),
        FingerInfo ("left-index-finger", _("Left index")),
        FingerInfo ("left-middle-finger", _("Left middle")),
        FingerInfo ("left-ring-finger", _("Left ring")),
        FingerInfo ("left-little-finger", _("Left little")),
        FingerInfo ("right-thumb", _("Right thumb")),
        FingerInfo ("right-index-finger", _("Right index")),
        FingerInfo ("right-middle-finger", _("Right middle")),
        FingerInfo ("right-ring-finger", _("Right ring")),
        FingerInfo ("right-little-finger", _("Right little"))
    };

    public MainWindow (Gtk.Application application) {
        Object (application: application, title: _("Fingerprint Login"));
        set_default_size (760, 540);
        set_size_request (660, 480);
        set_position (WindowPosition.CENTER);
        set_icon_name ("auth-fingerprint-symbolic");
        client = new FprintClient ();
        enrolled = new HashTable<string, string> (str_hash, str_equal);
        demo = Environment.get_variable ("MATE_FPRINT_DEMO") == "1";
        load_css ();
        build_ui ();
        delete_event.connect (() => {
            client.close ();
            return false;
        });
        Idle.add (() => {
            refresh ();
            return Source.REMOVE;
        });
    }

    private void load_css () {
        string[] candidates = {
            Path.build_filename (Config.PKGDATADIR, "mate-fprint.css"),
            Path.build_filename (Environment.get_current_dir (), "data", "mate-fprint.css")
        };
        foreach (string path in candidates) {
            if (FileUtils.test (path, FileTest.EXISTS)) {
                var provider = new CssProvider ();
                try {
                    provider.load_from_path (path);
                    StyleContext.add_provider_for_screen (
                        Gdk.Screen.get_default (), provider, STYLE_PROVIDER_PRIORITY_APPLICATION
                    );
                } catch (Error error) {
                }
                break;
            }
        }
    }

    private void build_ui () {
        var root = new Box (Orientation.VERTICAL, 0);
        root.pack_start (build_menubar (), false, false, 0);
        stack = new Stack ();
        stack.transition_type = StackTransitionType.CROSSFADE;
        stack.transition_duration = 160;
        root.pack_start (stack, true, true, 0);
        add (root);
        build_loading_page ();
        build_unavailable_page ();
        build_disabled_page ();
        build_overview_page ();
        build_detail_page ();
        build_enroll_page ();
    }

    private MenuBar build_menubar () {
        var bar = new MenuBar ();
        var accelerators = new AccelGroup ();
        add_accel_group (accelerators);
        var fingerprint_item = new Gtk.MenuItem.with_mnemonic (_("_Fingerprint"));
        var fingerprint_menu = new Gtk.Menu ();
        var refresh_item = new Gtk.MenuItem.with_mnemonic (_("_Refresh"));
        refresh_item.activate.connect (refresh);
        disable_item = new Gtk.MenuItem.with_mnemonic (_("_Disable Fingerprint Authentication"));
        disable_item.activate.connect (() => set_authentication (false));
        var quit_item = new Gtk.MenuItem.with_mnemonic (_("_Quit"));
        quit_item.activate.connect (() => application.quit ());
        add_menu_accelerator (quit_item, accelerators, "<Control>Q");
        add_menu_accelerator (quit_item, accelerators, "<Control>W");
        fingerprint_menu.append (refresh_item);
        fingerprint_menu.append (disable_item);
        fingerprint_menu.append (new SeparatorMenuItem ());
        fingerprint_menu.append (quit_item);
        fingerprint_item.set_submenu (fingerprint_menu);
        var help_item = new Gtk.MenuItem.with_mnemonic (_("_Help"));
        var help_menu = new Gtk.Menu ();
        var about_item = new Gtk.MenuItem.with_mnemonic (_("_About"));
        about_item.activate.connect (show_about);
        add_menu_accelerator (about_item, accelerators, "F1");
        help_menu.append (about_item);
        help_item.set_submenu (help_menu);
        bar.append (fingerprint_item);
        bar.append (help_item);
        return bar;
    }

    private void add_menu_accelerator (Gtk.MenuItem item, AccelGroup group, string accelerator) {
        uint key;
        Gdk.ModifierType modifiers;
        Gtk.accelerator_parse (accelerator, out key, out modifiers);
        item.add_accelerator ("activate", group, key, modifiers, AccelFlags.VISIBLE);
    }

    private Box centered_box () {
        var box = new Box (Orientation.VERTICAL, 4);
        box.halign = Align.CENTER;
        box.valign = Align.CENTER;
        return box;
    }

    private void build_loading_page () {
        var box = centered_box ();
        var spinner = new Spinner ();
        spinner.set_size_request (32, 32);
        spinner.start ();
        box.pack_start (spinner, false, false, 8);
        box.pack_start (new Label (_("Looking for a fingerprint reader…")), false, false, 8);
        stack.add_named (box, "loading");
    }

    private void build_unavailable_page () {
        var box = centered_box ();
        box.pack_start (new Image.from_icon_name ("dialog-warning", IconSize.DIALOG), false, false, 6);
        var title = new Label (null);
        title.set_markup (TITLE_MARKUP.printf (Markup.escape_text (_("No fingerprint reader detected"))));
        var detail = new Label (_("Connect a supported reader, then try again.\nThe fprintd service must also be installed and running."));
        detail.justify = Justification.CENTER;
        detail.get_style_context ().add_class ("dim-label");
        var retry = new Button.with_mnemonic (_("_Try Again"));
        retry.halign = Align.CENTER;
        retry.clicked.connect (refresh);
        box.pack_start (title, false, false, 6);
        box.pack_start (detail, false, false, 4);
        box.pack_start (retry, false, false, 14);
        stack.add_named (box, "unavailable");
    }

    private void build_disabled_page () {
        var box = centered_box ();
        var print = new Fingerprint (100);
        var title = new Label (null);
        title.set_markup (TITLE_MARKUP.printf (Markup.escape_text (_("Fingerprint authentication is disabled"))));
        var detail = new Label (_("Enable fingerprint authentication for login, screen unlocking,\nand administrative actions."));
        detail.justify = Justification.CENTER;
        detail.get_style_context ().add_class ("dim-label");
        var enable = new Button.with_mnemonic (_("_Enable Fingerprint Authentication"));
        enable.get_style_context ().add_class ("suggested-action");
        enable.halign = Align.CENTER;
        enable.clicked.connect (() => set_authentication (true));
        box.pack_start (print, false, false, 4);
        box.pack_start (title, false, false, 6);
        box.pack_start (detail, false, false, 4);
        box.pack_start (enable, false, false, 14);
        stack.add_named (box, "disabled");
    }

    private void build_overview_page () {
        var page = new Box (Orientation.VERTICAL, 18);
        page.border_width = 24;
        var heading = new Box (Orientation.HORIZONTAL, 14);
        var icon = new Fingerprint (72);
        icon.set_progress (1.0);
        var heading_text = new Box (Orientation.VERTICAL, 2);
        var title = new Label (null);
        title.set_markup (TITLE_MARKUP.printf (Markup.escape_text (_("Fingerprint Login"))));
        title.halign = Align.START;
        device_label = new Label (_("Fingerprint reader"));
        device_label.halign = Align.START;
        device_label.get_style_context ().add_class ("dim-label");
        heading_text.pack_start (title, false, false, 0);
        heading_text.pack_start (device_label, false, false, 0);
        heading.pack_start (icon, false, false, 0);
        heading.pack_start (heading_text, true, true, 0);
        page.pack_start (heading, false, false, 0);
        var frame = new Frame (_("Registered fingerprints"));
        finger_grid = new Grid ();
        finger_grid.column_spacing = 6;
        finger_grid.row_spacing = 6;
        finger_grid.border_width = 12;
        finger_grid.column_homogeneous = true;
        frame.add (finger_grid);
        page.pack_start (frame, true, true, 0);
        var hint = new Label (_("Select a finger to register, replace, or remove it."));
        hint.halign = Align.START;
        hint.get_style_context ().add_class ("dim-label");
        page.pack_start (hint, false, false, 0);
        stack.add_named (page, "overview");
    }

    private Button make_finger_button (FingerInfo finger, bool is_enrolled) {
        var button = new Button ();
        button.get_style_context ().add_class ("finger-button");
        var box = new Box (Orientation.VERTICAL, 4);
        var print = new Fingerprint (56);
        print.set_progress (is_enrolled ? 1.0 : 0.0, is_enrolled);
        var name = new Label (finger.label);
        var status = new Label (is_enrolled ? _("Registered") : _("Not registered"));
        status.get_style_context ().add_class ("dim-label");
        box.pack_start (print, false, false, 0);
        box.pack_start (name, false, false, 0);
        box.pack_start (status, false, false, 0);
        button.add (box);
        button.clicked.connect (() => select_finger (finger, is_enrolled));
        return button;
    }

    private void build_detail_page () {
        var page = new Box (Orientation.VERTICAL, 16);
        page.border_width = 24;
        var back = new Button.with_mnemonic ("←  _All Fingers");
        back.halign = Align.START;
        back.clicked.connect (show_overview);
        page.pack_start (back, false, false, 0);
        var center = centered_box ();
        detail_print = new Fingerprint (128);
        detail_title = new Label (null);
        detail_status = new Label (null);
        detail_status.get_style_context ().add_class ("dim-label");
        center.pack_start (detail_print, false, false, 4);
        center.pack_start (detail_title, false, false, 4);
        center.pack_start (detail_status, false, false, 0);
        page.pack_start (center, true, true, 0);
        var actions = new ButtonBox (Orientation.HORIZONTAL);
        actions.layout_style = ButtonBoxStyle.END;
        actions.spacing = 8;
        remove_button = new Button.with_mnemonic (_("_Remove"));
        remove_button.get_style_context ().add_class ("destructive-action");
        remove_button.clicked.connect (remove_current);
        enroll_button = new Button.with_mnemonic (_("_Register"));
        enroll_button.get_style_context ().add_class ("suggested-action");
        enroll_button.clicked.connect (begin_enrollment);
        actions.add (remove_button);
        actions.add (enroll_button);
        page.pack_start (actions, false, false, 0);
        stack.add_named (page, "detail");
    }

    private void build_enroll_page () {
        var page = new Box (Orientation.VERTICAL, 10);
        page.border_width = 24;
        enroll_title = new Label (null);
        page.pack_start (enroll_title, false, false, 6);
        var center = centered_box ();
        enroll_print = new Fingerprint (170);
        enroll_instruction = new Label (_("Place your finger on the reader"));
        enroll_instruction.get_style_context ().add_class ("enroll-instruction");
        enroll_status = new Label (_("Lift and place the same finger again after each scan."));
        enroll_status.justify = Justification.CENTER;
        enroll_status.get_style_context ().add_class ("dim-label");
        progress_bar = new ProgressBar ();
        progress_bar.set_size_request (360, -1);
        center.pack_start (enroll_print, false, false, 4);
        center.pack_start (enroll_instruction, false, false, 6);
        center.pack_start (enroll_status, false, false, 0);
        center.pack_start (progress_bar, false, false, 10);
        page.pack_start (center, true, true, 0);
        cancel_button = new Button.with_mnemonic (_("_Cancel"));
        cancel_button.halign = Align.END;
        cancel_button.clicked.connect (cancel_enrollment);
        page.pack_start (cancel_button, false, false, 0);
        stack.add_named (page, "enroll");
    }

    private bool authentication_enabled () {
        string contents;
        try {
            FileUtils.get_contents ("/etc/pam.d/common-auth", out contents);
            return contents.contains ("pam_fprintd.so");
        } catch (FileError error) {
            return false;
        }
    }

    private void set_authentication (bool enabled) {
        string action = enabled ? "--enable" : "--disable";
        try {
            var process = new Subprocess.newv (
                { "pkexec", "pam-auth-update", "--package", action, "mate-fprint" },
                SubprocessFlags.NONE
            );
            process.wait_check_async.begin (null, (object, result) => {
                try {
                    if (!process.wait_check_async.end (result)) {
                        show_error (_("Could not change fingerprint authentication"), _("The system configuration command failed."));
                    }
                    refresh ();
                } catch (Error error) {
                    show_error (_("Could not change fingerprint authentication"), error.message);
                }
            });
        } catch (Error error) {
            show_error (_("Could not change fingerprint authentication"), error.message);
        }
    }

    private void refresh () {
        stack.visible_child_name = "loading";
        while (Gtk.events_pending ()) {
            Gtk.main_iteration_do (false);
        }
        try {
            string name;
            if (demo) {
                name = _("Demo fingerprint reader");
                enrolled.remove_all ();
                enrolled.insert ("left-index-finger", "left-index-finger");
                enrolled.insert ("right-index-finger", "right-index-finger");
            } else {
                name = client.connect_device ();
                if (name == "") {
                    disable_item.sensitive = false;
                    stack.visible_child_name = "unavailable";
                    return;
                }
                if (!authentication_enabled ()) {
                    disable_item.sensitive = false;
                    stack.visible_child_name = "disabled";
                    return;
                }
                client.claim ();
                enrolled = client.list_enrolled ();
            }
            disable_item.sensitive = !demo;
            populate (name);
        } catch (Error error) {
            disable_item.sensitive = false;
            stack.visible_child_name = "unavailable";
        }
    }

    private void populate (string device_name) {
        device_label.label = device_name;
        foreach (unowned Widget child in finger_grid.get_children ()) {
            finger_grid.remove (child);
        }
        for (int index = 0; index < fingers.length; index++) {
            finger_grid.attach (
                make_finger_button (fingers[index], enrolled.contains (fingers[index].id)),
                index % 5,
                index / 5,
                1,
                1
            );
        }
        finger_grid.show_all ();
        stack.visible_child_name = "overview";
    }

    private void select_finger (FingerInfo finger, bool is_enrolled) {
        current_finger = finger.id;
        current_label = finger.label;
        detail_title.set_markup (TITLE_MARKUP.printf (Markup.escape_text (finger.label)));
        detail_print.set_progress (is_enrolled ? 1.0 : 0.0, is_enrolled);
        detail_status.label = is_enrolled ? _("This fingerprint is registered.") : _("This fingerprint is not registered.");
        remove_button.visible = is_enrolled;
        enroll_button.visible = !is_enrolled;
        enroll_button.label = _("_Register");
        enroll_button.use_underline = true;
        stack.visible_child_name = "detail";
    }

    private void begin_enrollment () {
        scans = 0;
        stages = demo ? 5 : client.get_enroll_stages ();
        // Translators: %s is a finger name in lowercase, such as "left index".
        enroll_title.set_markup (TITLE_MARKUP.printf (Markup.escape_text (_("Register %s").printf (current_label.down ()))));
        enroll_instruction.label = _("Place your finger on the reader");
        enroll_status.label = _("Lift and place the same finger again after each scan.");
        progress_bar.fraction = 0;
        progress_bar.show_text = false;
        enroll_print.set_progress (0);
        cancel_button.label = _("_Cancel");
        cancel_button.use_underline = true;
        stack.visible_child_name = "enroll";
        if (demo) {
            Timeout.add (700, demo_scan);
            return;
        }
        try {
            client.start_enrollment (current_finger, enroll_signal);
        } catch (Error error) {
            show_error (_("Could not start enrollment"), error.message);
            stack.visible_child_name = "detail";
        }
    }

    private bool demo_scan () {
        if (stack.visible_child_name != "enroll") {
            return Source.REMOVE;
        }
        enroll_signal ("enroll-stage-passed", false);
        if (scans >= stages) {
            enroll_signal ("enroll-completed", true);
            return Source.REMOVE;
        }
        return Source.CONTINUE;
    }

    private void enroll_signal (string status, bool done) {
        if (status == "enroll-stage-passed") {
            scans = int.min (stages, scans + 1);
            double fraction = (double) scans / stages;
            progress_bar.fraction = fraction;
            // Translators: the first %d is the number of completed scans, the second the total.
            progress_bar.text = ngettext ("%d of %d scan", "%d of %d scans", stages).printf (scans, stages);
            progress_bar.show_text = true;
            enroll_print.set_progress (fraction);
            enroll_instruction.label = _("Good scan! Keep going.");
            enroll_status.label = _("Lift your finger, then place it on the reader again.");
            return;
        }
        if (status == "enroll-completed") {
            enrolled.insert (current_finger, current_finger);
            progress_bar.fraction = 1;
            progress_bar.text = _("Complete");
            progress_bar.show_text = true;
            enroll_print.set_progress (1, true);
            enroll_instruction.label = _("Fingerprint registered");
            enroll_status.label = _("You can now use this finger to authenticate.");
            cancel_button.label = _("_Done");
            cancel_button.use_underline = true;
            stop_enrollment_safely ();
            return;
        }
        switch (status) {
            case "enroll-remove-and-retry":
                enroll_instruction.label = _("Try that scan again");
                enroll_status.label = _("Remove your finger completely, then place it on the reader.");
                break;
            case "enroll-retry-scan":
                enroll_instruction.label = _("Try that scan again");
                enroll_status.label = _("Move your finger slightly and try again.");
                break;
            case "enroll-swipe-too-short":
                enroll_instruction.label = _("The swipe was too short");
                enroll_status.label = _("Swipe the full length of your finger over the reader.");
                break;
            case "enroll-finger-not-centered":
                enroll_instruction.label = _("Center your finger");
                enroll_status.label = _("Place the middle of your fingertip on the reader.");
                break;
            case "enroll-duplicate":
                enroll_instruction.label = _("Fingerprint already registered");
                enroll_status.label = _("Choose a different finger or remove the existing fingerprint first.");
                break;
            case "enroll-data-full":
                enroll_instruction.label = _("Fingerprint storage is full");
                enroll_status.label = _("Remove a fingerprint before registering another one.");
                break;
            case "enroll-disconnected":
                enroll_instruction.label = _("Reader disconnected");
                enroll_status.label = _("Reconnect the fingerprint reader and try again.");
                break;
            default:
                enroll_instruction.label = _("Fingerprint was not registered");
                enroll_status.label = _("Please cancel and try again.");
                break;
        }
        if (done || status == "enroll-duplicate" || status == "enroll-data-full" || status == "enroll-disconnected" || status == "enroll-failed") {
            cancel_button.label = _("_Back");
            cancel_button.use_underline = true;
            stop_enrollment_safely ();
        }
    }

    private void stop_enrollment_safely () {
        if (!demo) {
            try {
                client.stop_enrollment ();
            } catch (Error error) {
            }
        }
    }

    private void cancel_enrollment () {
        stop_enrollment_safely ();
        show_overview ();
    }

    private void show_overview () {
        populate (device_label.label);
    }

    private void remove_current () {
        var dialog = new MessageDialog (
            this,
            DialogFlags.MODAL,
            MessageType.QUESTION,
            ButtonsType.CANCEL,
            // Translators: %s is a finger name in lowercase, such as "left index".
            _("Remove %s?"),
            current_label.down ()
        );
        dialog.format_secondary_text (_("You will no longer be able to authenticate with this fingerprint."));
        var remove = dialog.add_button (_("_Remove"), ResponseType.ACCEPT);
        remove.get_style_context ().add_class ("destructive-action");
        int response = dialog.run ();
        dialog.destroy ();
        if (response != ResponseType.ACCEPT) {
            return;
        }
        try {
            if (!demo) {
                client.delete_finger (current_finger);
            }
            enrolled.remove (current_finger);
            show_overview ();
        } catch (Error error) {
            show_error (_("Could not remove fingerprint"), error.message);
        }
    }

    private void show_error (string title, string detail) {
        var dialog = new MessageDialog (
            this, DialogFlags.MODAL, MessageType.ERROR, ButtonsType.CLOSE, "%s", title
        );
        dialog.format_secondary_text (detail);
        dialog.run ();
        dialog.destroy ();
    }

    private void show_about () {
        var dialog = new AboutDialog ();
        dialog.transient_for = this;
        dialog.modal = true;
        dialog.program_name = _("Fingerprint Login");
        dialog.version = Config.VERSION;
        dialog.comments = _("Manage fingerprint authentication for the MATE desktop");
        dialog.logo_icon_name = "auth-fingerprint-symbolic";
        dialog.license_type = License.GPL_3_0;
        dialog.run ();
        dialog.destroy ();
    }
}

class MateFprintApplication : Gtk.Application {
    public MateFprintApplication () {
        Object (application_id: APP_ID, flags: ApplicationFlags.FLAGS_NONE);
    }

    protected override void activate () {
        var window = active_window;
        if (window == null) {
            window = new MainWindow (this);
        }
        window.show_all ();
        window.present ();
    }
}

int main (string[] args) {
    Intl.setlocale (LocaleCategory.ALL, "");
    Intl.bindtextdomain (Config.GETTEXT_PACKAGE, Config.LOCALEDIR);
    Intl.bind_textdomain_codeset (Config.GETTEXT_PACKAGE, "UTF-8");
    Intl.textdomain (Config.GETTEXT_PACKAGE);
    return new MateFprintApplication ().run (args);
}
