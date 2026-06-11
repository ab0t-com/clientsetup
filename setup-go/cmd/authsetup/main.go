// Command authsetup is the Go rewrite of the Auth Mesh client setup kit.
//
// Usage:
//
//	authsetup [global flags] <command> [args]
//
// Commands:
//
//	validate              check config files; exits non-zero on problems
//	run [step ...]        run the setup pipeline (steps 01..08, or a subset)
//	status                read-only: report server state vs config (alias of step 05)
//	backfill              reconcile EXISTING workspace teams to default_grant
//	version               print version
//
// Global flags:
//
//	--base-url URL        auth service (default $AUTH_SERVICE_URL or prod)
//	--config-dir DIR      config directory (default ../config relative to binary, then ./config)
//	--creds-dir DIR       credentials directory (default sibling of config-dir)
//	--dry-run             read everything, mutate nothing; print the plan
//	--skip-validate       run even when config validation fails (discouraged)
//
// Backfill flags:
//
//	--only-org ID         restrict to one workspace org (validation runs)
//	--extra-perm P        repeatable; perms beyond default_grant
//
// Conventions: see ARCHITECTURE.md. Every command ends with a NEXT block.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/ab0t-com/client-service-setup-cli/setup-go/internal/api"
	"github.com/ab0t-com/client-service-setup-cli/setup-go/internal/config"
	"github.com/ab0t-com/client-service-setup-cli/setup-go/internal/creds"
	"github.com/ab0t-com/client-service-setup-cli/setup-go/internal/steps"
	"github.com/ab0t-com/client-service-setup-cli/setup-go/internal/ui"
)

const version = "0.2.0"

const defaultBaseURL = "https://auth.service.ab0t.com"

func main() {
	if err := run(); err != nil {
		ui.Errorf("%v", err)
		os.Exit(1)
	}
}

func run() error {
	var (
		baseURL      = flag.String("base-url", envOr("AUTH_SERVICE_URL", defaultBaseURL), "auth service base URL")
		configDir    = flag.String("config-dir", "", "config directory (default: ./config)")
		credsDir     = flag.String("creds-dir", "", "credentials directory (default: ~/.authmesh/<service-id>; env AUTHSETUP_CREDS_DIR)")
		writeIgnore  = flag.Bool("write-gitignore", false, "if the creds dir is inside a git repo and not ignored, append a .gitignore entry")
		unsafeCreds  = flag.Bool("unsafe-creds-in-repo", false, "proceed even if the creds dir is inside a git repo and not gitignored (discouraged)")
		dryRun       = flag.Bool("dry-run", false, "mutate nothing; print the plan")
		skipValidate = flag.Bool("skip-validate", false, "run even when config validation fails (discouraged)")
		onlyOrg      = flag.String("only-org", "", "backfill: restrict to one workspace org id")
		extraPerms   multiFlag
	)
	flag.Var(&extraPerms, "extra-perm", "backfill: extra permission (repeatable)")
	flag.Parse()

	cmd := flag.Arg(0)
	if cmd == "" || cmd == "help" {
		flag.Usage()
		return nil
	}
	if cmd == "version" {
		fmt.Println("authsetup", version)
		return nil
	}

	cfgDir := *configDir
	if cfgDir == "" {
		cfgDir = "config"
	}

	cfg, err := config.Load(cfgDir)
	if err != nil {
		return err
	}

	// Credentials directory: default OUTSIDE any repo (~/.authmesh/<service>),
	// named per service. See internal/creds/resolve.go for the policy.
	res, err := creds.Resolve(*credsDir, cfg.Permissions.Service.ID)
	if err != nil {
		return err
	}
	crDir := res.Dir

	// Validation gates every command except itself being asked for.
	problems := cfg.Validate()
	if cmd == "validate" {
		if len(problems) == 0 {
			ui.Successf("config valid: service %q, %d permissions (%d default_grant), %d roles, pattern %q",
				cfg.Permissions.Service.ID, len(cfg.Permissions.Permissions),
				len(cfg.Permissions.DefaultGrantIDs()), len(cfg.Permissions.Roles),
				orFlat(cfg.Permissions.EndUsers.OrgStructure.Pattern))
			ui.Next("authsetup --dry-run run    # preview the full reconcile plan",
				"WHY: dry-run reads live server state and shows exactly what would change.")
			return nil
		}
		for _, p := range problems {
			ui.Errorf("%s", p)
		}
		return fmt.Errorf("%d config problem(s)", len(problems))
	}
	if len(problems) > 0 && !*skipValidate {
		for _, p := range problems {
			ui.Errorf("%s", p)
		}
		return fmt.Errorf("%d config problem(s) — fix them or pass --skip-validate (discouraged)", len(problems))
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	sc := &steps.Context{
		Ctx:    ctx,
		API:    api.New(*baseURL),
		Cfg:    cfg,
		Creds:  creds.New(crDir, *baseURL),
		DryRun: *dryRun,
	}

	if cmd == "info" {
		fmt.Println("authsetup", version)
		fmt.Println("  auth service :", *baseURL, "(env suffix:", orNone(sc.Creds.Suffix)+")")
		fmt.Println("  config dir   :", cfgDir)
		fmt.Println("  creds dir    :", res.Describe())
		fmt.Println("  service      :", cfg.Permissions.Service.ID)
		fmt.Println("  org pattern  :", orFlat(cfg.Permissions.EndUsers.OrgStructure.Pattern))
		fmt.Println("  default role :", cfg.Permissions.DefaultRole())
		fmt.Println("  default_grant:", cfg.Permissions.DefaultGrantIDs())
		entries, _ := os.ReadDir(crDir)
		fmt.Println("  state files  :")
		for _, e := range entries {
			if !e.IsDir() {
				fmt.Println("    -", e.Name())
			}
		}
		ui.Next("authsetup status            # compare this state against the live server",
			"WHY: info is local-only; status reads the server.")
		return nil
	}

	// Git-safety gate for anything that can write credentials.
	if (cmd == "run" || cmd == "backfill") && res.Unsafe() && !*unsafeCreds {
		ui.Warnf("credentials dir is inside a git repository and NOT gitignored:")
		ui.Warnf("  %s", res.Describe())
		switch {
		case *writeIgnore:
			if err := res.WriteGitignore(); err != nil {
				return err
			}
			ui.Successf("appended ignore entry to %s/.gitignore", res.RepoRoot)
		case isTTY():
			fmt.Print("Append a .gitignore entry now? [y/N] ")
			var ans string
			fmt.Scanln(&ans)
			if ans == "y" || ans == "Y" || ans == "yes" {
				if err := res.WriteGitignore(); err != nil {
					return err
				}
				ui.Successf("appended ignore entry to %s/.gitignore", res.RepoRoot)
			} else {
				return fmt.Errorf("refusing to write credentials into an unignored repo path — re-run with --write-gitignore, --unsafe-creds-in-repo, or choose a different --creds-dir")
			}
		default:
			return fmt.Errorf("creds dir %s is inside a git repo and not gitignored; re-run with --write-gitignore (recommended) or --unsafe-creds-in-repo, or set AUTHSETUP_CREDS_DIR outside the repo", crDir)
		}
	}

	// Compliance journal: every HTTP exchange (input + output, secrets
	// redacted) is appended to <creds>/journal/run-<ts>.jsonl, tagged with
	// the pipeline step. See internal/creds/journal.go.
	journal, err := sc.Creds.OpenJournal()
	if err != nil {
		return fmt.Errorf("opening run journal: %w", err)
	}
	defer journal.Close()
	sc.API.Recorder = func(rec api.CallRecord) { _ = journal.Write(rec) }
	sc.API.StepTag = func() string {
		if sc.CurrentStep != "" {
			return sc.CurrentStep
		}
		return cmd
	}

	ui.Infof("auth service: %s%s", *baseURL, map[bool]string{true: "  [DRY RUN]", false: ""}[*dryRun])
	ui.Infof("credentials : %s", res.Describe())
	ui.Infof("journal     : %s", journal.Path)
	if err := sc.API.Health(ctx); err != nil {
		return fmt.Errorf("auth service unreachable at %s: %w", *baseURL, err)
	}

	switch cmd {
	case "run":
		list, err := steps.Find(flag.Args()[1:])
		if err != nil {
			return err
		}
		if err := steps.Run(sc, list); err != nil {
			ui.Next("fix the failure above, then re-run — every step reconciles, so re-runs are safe.",
				"WHY: state already converged is a no-op; only the failed remainder applies.")
			return err
		}
		if *dryRun {
			ui.Next("authsetup run               # apply the plan above",
				"WHY: dry-run mutated nothing; the plan reflects live server state at this moment.")
		} else {
			ui.Next("authsetup run 05            # independent verification pass",
				"authsetup run 06            # end-to-end test user (creates a throwaway account)",
				"WHY: 05/06 prove the converged state actually authenticates and authorizes.")
		}
		return nil

	case "status":
		err := steps.Run(sc, mustFind("05"))
		if err == nil {
			ui.Next("nothing to do — server matches config.",
				"To roll out a NEW default_grant permission to existing workspace users: authsetup backfill")
		} else {
			ui.Next("authsetup run               # reconcile the drift reported above")
		}
		return err

	case "backfill":
		bf := &steps.S09Backfill{OnlyOrgID: *onlyOrg, ExtraPerms: extraPerms}
		if err := steps.Run(sc, []steps.Step{bf}); err != nil {
			return err
		}
		if *dryRun {
			ui.Next("validate ONE workspace first: authsetup backfill --only-org <org_id>",
				"then the full sweep:          authsetup backfill",
				"WHY: prove the team-update lever end-to-end on one user before touching all tenants.")
		} else {
			ui.Next("have one affected user re-login and retry the previously-403 endpoint.",
				"WHY: confirms cache rollover and the Zanzibar re-sync took effect.")
		}
		return nil

	default:
		return fmt.Errorf("unknown command %q (try: validate, run, status, backfill, info, version)", cmd)
	}
}

func mustFind(id string) []steps.Step {
	s, err := steps.Find([]string{id})
	if err != nil {
		panic(err)
	}
	return s
}

func isTTY() bool {
	fi, err := os.Stdin.Stat()
	return err == nil && fi.Mode()&os.ModeCharDevice != 0
}

func orNone(s string) string {
	if s == "" {
		return "none"
	}
	return s
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func orFlat(s string) string {
	if s == "" {
		return "flat"
	}
	return s
}

type multiFlag []string

func (m *multiFlag) String() string     { return fmt.Sprint([]string(*m)) }
func (m *multiFlag) Set(v string) error { *m = append(*m, v); return nil }
