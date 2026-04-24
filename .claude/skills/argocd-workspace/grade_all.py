#!/usr/bin/env python3
"""Grade all ArgoCD eval runs against assertions."""
import json, re, os

BASE = "/Users/chris/Documents/github/AI-powered-SRE/.claude/skills/argocd-workspace/iteration-1"

def read(path):
    try:
        with open(path) as f:
            return f.read().lower()
    except FileNotFoundError:
        return ""

def grade_eval1(text):
    results = []
    checks = [
        ("uses-ha-manifest",        "Uses the HA install manifest path (ha/install.yaml)",
         bool(re.search(r'ha/install\.yaml', text))),
        ("correct-version",         "References ArgoCD v3.3.8 specifically",
         bool(re.search(r'v3\.3\.8', text))),
        ("rbac-default-readonly",   "argocd-rbac-cm sets policy.default to role:readonly",
         bool(re.search(r'policy\.default.*role:readonly', text))),
        ("eks-irsa-cluster-secret", "EKS cluster secret uses awsAuthConfig (IRSA pattern)",
         bool(re.search(r'awsauthconfig', text))),
        ("repo-secret-label",       "Repository secret has argocd.argoproj.io/secret-type: repository label",
         bool(re.search(r'argocd\.argoproj\.io/secret-type.*repository', text))),
        ("delete-initial-admin-secret", "Mentions deleting argocd-initial-admin-secret",
         bool(re.search(r'argocd-initial-admin-secret', text)) and
         bool(re.search(r'delet|remov|rotat', text))),
        ("named-appproject",        "Creates a named AppProject (not just default project)",
         bool(re.search(r'kind:\s*appproject', text))),
        ("app-of-apps-pattern",     "Includes/recommends App-of-Apps root Application",
         bool(re.search(r'app.of.app|root.app|apps/.*apps', text))),
    ]
    for name, desc, passed in checks:
        evidence = "Pattern found in response" if passed else "Pattern NOT found in response"
        results.append({"text": desc, "passed": passed, "evidence": evidence})
    return results

def grade_eval2(text):
    results = []
    checks = [
        ("uses-oidc-config-not-dex", "Uses oidc.config in argocd-cm (not dex.config for Okta)",
         bool(re.search(r'oidc\.config', text))),
        ("secret-reference-not-plaintext", "ClientSecret via $oidc.okta.clientSecret or $dex. reference",
         bool(re.search(r'\$oidc\.\|\\$dex\.', text)) or
         bool(re.search(r'\$oidc\.okta\|secretkeyref\|secretref', text)) or
         bool(re.search(r'\$oidc', text)) or bool(re.search(r'external.secret\|sealed.secret', text))),
        ("policy-default-readonly", "argocd-rbac-cm sets policy.default: role:readonly",
         bool(re.search(r'policy\.default.*role:readonly', text))),
        ("all-three-groups-mapped", "All three Okta groups mapped to roles",
         all(g in text for g in ['okta-platform-admins', 'okta-dev-team-frontend', 'okta-dev-team-backend'])),
        ("developer-role-sync-get-only", "Developer role limited to sync/get (no create/delete)",
         bool(re.search(r'role:dev.*get|role:dev.*sync', text)) and
         not bool(re.search(r'role:dev.*(create|delete).*allow', text))),
        ("groups-scope-requested", "requestedScopes includes 'groups'",
         bool(re.search(r'requestedscopes.*groups|groups.*requestedscopes|scope.*groups', text))),
        ("disable-admin-after-sso", "Mentions disabling admin user after SSO",
         bool(re.search(r'admin\.enabled.*false|disable.*admin', text))),
    ]
    for name, desc, passed in checks:
        evidence = "Pattern found" if passed else "Pattern NOT found"
        results.append({"text": desc, "passed": passed, "evidence": evidence})
    return results

def grade_eval3(text):
    results = []
    checks = [
        ("sourcerepos-wildcard", "sourceRepos uses wildcard payments-*",
         bool(re.search(r'payments-\*', text))),
        ("destinations-both-namespaces", "Destinations include both payments-prod AND payments-staging",
         bool(re.search(r'payments-prod', text)) and bool(re.search(r'payments-staging', text))),
        ("cluster-resource-namespace-only", "clusterResourceWhitelist allows only Namespace",
         bool(re.search(r'clusterresourcewhitelist', text)) and
         bool(re.search(r'kind:\s*namespace', text))),
        ("namespace-resource-four-kinds", "namespaceResourceWhitelist covers all 4 kinds",
         all(k in text for k in ['deployment', 'service', 'configmap', 'horizontalpodautoscaler'])),
        ("two-project-roles", "Defines two project roles",
         len(re.findall(r'- name:\s*\w+', text)) >= 2),
        ("developer-role-sync-only", "Developer role limited to sync/get (no create/delete)",
         bool(re.search(r'developer.*sync|payments.developer.*sync', text)) and
         not bool(re.search(r'payments.developer.*(create|delete).*allow', text))),
        ("finalizer-present", "AppProject has resources-finalizer.argocd.argoproj.io",
         bool(re.search(r'resources-finalizer\.argocd\.argoproj\.io', text))),
        ("destination-in-cluster", "Destination server is kubernetes.default.svc",
         bool(re.search(r'kubernetes\.default\.svc', text))),
    ]
    for name, desc, passed in checks:
        evidence = "Pattern found" if passed else "Pattern NOT found"
        results.append({"text": desc, "passed": passed, "evidence": evidence})
    return results

GRADERS = {1: grade_eval1, 2: grade_eval2, 3: grade_eval3}
EVAL_NAMES = {1: "eks-ha-production-install", 2: "okta-oidc-rbac-setup", 3: "appproject-payments-team"}

for eval_id in [1, 2, 3]:
    for variant in ["with_skill", "without_skill"]:
        response_path = f"{BASE}/eval-{eval_id}/{variant}/outputs/response.md"
        grading_path  = f"{BASE}/eval-{eval_id}/{variant}/grading.json"
        text = read(response_path)
        if not text:
            print(f"MISSING: {response_path}")
            continue
        assertions = GRADERS[eval_id](text)
        passed = sum(1 for a in assertions if a["passed"])
        total  = len(assertions)
        grading = {
            "eval_id": eval_id,
            "eval_name": EVAL_NAMES[eval_id],
            "variant": variant,
            "pass_rate": round(passed / total, 3),
            "passed": passed,
            "total": total,
            "expectations": assertions
        }
        with open(grading_path, "w") as f:
            json.dump(grading, f, indent=2)
        print(f"eval-{eval_id}/{variant}: {passed}/{total} ({grading['pass_rate']*100:.0f}%)")
