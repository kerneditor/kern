#!/usr/bin/env python3
"""Generate mega-stress-test.md — 5000+ lines covering all edge cases."""
import os

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT = os.path.join(ROOT, "test-fixtures", "mega-stress-test.md")
lines = []
def w(s=""): lines.append(s)

# ═══════════════════════════════════════════════════════════════════
# SECTION 1: NESTED CHECKLIST BUG TESTS
# ═══════════════════════════════════════════════════════════════════
w("# Kern Mega Stress Test (5000+ lines)")
w()
w("## Section 1: Nested Checklist Bug Tests")
w()
w("### Test 1A: Basic checked vs unchecked")
w("Only checked items should be struck through:")
w()
w("- [x] Checked — SHOULD be struck through")
w("- [ ] Unchecked — should NOT be struck through")
w("- [x] Checked — SHOULD be struck through")
w("- [ ] Unchecked — should NOT be struck through")
w()

w("### Test 1B: Checked items inside unchecked parent")
w("Parent bullets should NOT inherit strikethrough from children:")
w()
w("- Parent bullet (should be NORMAL)")
w("  - [x] Child checked (struck through)")
w("  - [ ] Child unchecked (normal)")
w("  - [x] Child checked (struck through)")
w("- Another parent (should be NORMAL)")
w("  - [ ] Child unchecked (normal)")
w("  - [x] Child checked (struck through)")
w()

w("### Test 1C: Unchecked items inside checked parent")
w()
w("- [x] Parent checked (struck through)")
w("  - [ ] Child unchecked — should this inherit parent strike?")
w("  - [x] Child checked (struck through)")
w("- [ ] Parent unchecked (normal)")
w("  - [x] Child checked (struck through)")
w("  - [ ] Child unchecked (normal)")
w()

w("### Test 1D: 4-level deep nesting")
w()
w("- Level 0 bullet (NORMAL)")
w("  - [x] Level 1 checked (struck)")
w("    - [ ] Level 2 unchecked (normal)")
w("      - [x] Level 3 checked (struck)")
w("      - [ ] Level 3 unchecked (normal)")
w("    - [x] Level 2 checked (struck)")
w("      - [ ] Level 3 unchecked (normal)")
w("  - [ ] Level 1 unchecked (normal)")
w("    - [x] Level 2 checked (struck)")
w("    - [ ] Level 2 unchecked (normal)")
w()

w("### Test 1E: Mixed checked/unchecked at every level")
w()
w("- [ ] L0 unchecked")
w("  - [x] L1 checked")
w("    - [ ] L2 unchecked")
w("      - [x] L3 checked")
w("    - [x] L2 checked")
w("      - [ ] L3 unchecked")
w("  - [ ] L1 unchecked")
w("    - [x] L2 checked")
w("    - [ ] L2 unchecked")
w("- [x] L0 checked")
w("  - [ ] L1 unchecked")
w("    - [x] L2 checked")
w("  - [x] L1 checked")
w("    - [ ] L2 unchecked")
w()

w("### Test 1F: Checklist inside ordered list")
w()
w("1. First ordered item (NORMAL)")
w("   - [x] Sub-task done (struck)")
w("   - [ ] Sub-task pending (normal)")
w("2. Second ordered item (NORMAL)")
w("   - [x] Done (struck)")
w("   - [x] Done (struck)")
w("3. Third ordered item (NORMAL)")
w("   - [ ] Pending (normal)")
w("   - [ ] Pending (normal)")
w()

w("### Test 1G: Checklist with rich content")
w()
w("- [x] **Bold checked** — struck through with bold")
w("- [ ] *Italic unchecked* — normal with italic")
w("- [x] `Code checked` — struck through with code")
w("- [ ] [Link unchecked](https://example.com) — normal with link")
w("- [x] **Bold** and *italic* and `code` and [link](https://example.com) — all struck")
w("- [ ] ~~Already strikethrough~~ unchecked — normal (double strike?)")
w()

w("### Test 1H: All-checked list")
w()
w("- [x] Item 1")
w("- [x] Item 2")
w("- [x] Item 3")
w("- [x] Item 4")
w("- [x] Item 5")
w()

w("### Test 1I: All-unchecked list")
w()
w("- [ ] Item 1")
w("- [ ] Item 2")
w("- [ ] Item 3")
w("- [ ] Item 4")
w("- [ ] Item 5")
w()

w("### Test 1J: Single checked in long list")
w()
for i in range(1, 21):
    checked = "x" if i == 10 else " "
    w(f"- [{checked}] Item {i}" + (" ← only this one struck" if i == 10 else ""))
w()

w("### Test 1K: Checklist inside blockquote")
w()
w("> Project tasks:")
w("> - [x] Design complete")
w("> - [ ] Implementation pending")
w("> - [x] Tests written")
w("> - [ ] Documentation needed")
w()

# ═══════════════════════════════════════════════════════════════════
# SECTION 2: CODE BLOCKS — EVERY LANGUAGE
# ═══════════════════════════════════════════════════════════════════
w("---")
w()
w("## Section 2: Code Blocks — Every Language")
w()

code_blocks = {
"javascript": '''// DOM manipulation + async
async function fetchUsers(apiUrl) {
  const response = await fetch(apiUrl);
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const users = await response.json();
  const list = document.getElementById("user-list");
  users.forEach(({ name, email, id }) => {
    const li = document.createElement("li");
    li.textContent = `${name} <${email}>`;
    li.dataset.userId = id;
    list.appendChild(li);
  });
  return users.length;
}
fetchUsers("https://api.example.com/users").then(console.log);''',

"typescript": '''// Generic utility types + decorators
interface Repository<T extends { id: string }> {
  findById(id: string): Promise<T | null>;
  findAll(filter?: Partial<T>): Promise<T[]>;
  save(entity: T): Promise<T>;
  delete(id: string): Promise<boolean>;
}

type ReadOnly<T> = { readonly [K in keyof T]: T[K] };

class UserRepo implements Repository<User> {
  private cache = new Map<string, User>();

  async findById(id: string): Promise<User | null> {
    return this.cache.get(id) ?? null;
  }
  async findAll(filter?: Partial<User>): Promise<User[]> {
    return [...this.cache.values()].filter(u =>
      !filter || Object.entries(filter).every(([k, v]) => u[k as keyof User] === v)
    );
  }
  async save(entity: User): Promise<User> {
    this.cache.set(entity.id, entity);
    return entity;
  }
  async delete(id: string): Promise<boolean> {
    return this.cache.delete(id);
  }
}''',

"python": '''# Dataclass + context manager + generator
from dataclasses import dataclass, field
from contextlib import contextmanager
from typing import Generator, Optional
import logging

logger = logging.getLogger(__name__)

@dataclass
class DatabaseConfig:
    host: str = "localhost"
    port: int = 5432
    database: str = "myapp"
    pool_size: int = 10
    _connections: list = field(default_factory=list, repr=False)

    @contextmanager
    def connect(self) -> Generator:
        conn = f"conn://{self.host}:{self.port}/{self.database}"
        self._connections.append(conn)
        logger.info(f"Opened {conn} (pool: {len(self._connections)})")
        try:
            yield conn
        finally:
            self._connections.remove(conn)
            logger.info(f"Closed {conn}")

    def query(self, sql: str, params: Optional[tuple] = None):
        with self.connect() as conn:
            return f"[{conn}] {sql} {params or ''}"''',

"rust": '''// Traits, enums, pattern matching, lifetimes
use std::collections::HashMap;
use std::fmt;

#[derive(Debug, Clone)]
enum Token<'a> {
    Number(f64),
    String(&'a str),
    Identifier(&'a str),
    Operator(char),
    Eof,
}

impl<'a> fmt::Display for Token<'a> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Token::Number(n) => write!(f, "NUM({})", n),
            Token::String(s) => write!(f, "STR(\\"{}\\")", s),
            Token::Identifier(id) => write!(f, "ID({})", id),
            Token::Operator(op) => write!(f, "OP({})", op),
            Token::Eof => write!(f, "EOF"),
        }
    }
}

fn tokenize(input: &str) -> Vec<Token> {
    let mut tokens = Vec::new();
    let mut chars = input.chars().peekable();
    while let Some(&ch) = chars.peek() {
        match ch {
            '0'..='9' => {
                let num: String = std::iter::from_fn(|| {
                    chars.peek().filter(|c| c.is_ascii_digit() || **c == '.').map(|_| chars.next().unwrap())
                }).collect();
                tokens.push(Token::Number(num.parse().unwrap()));
            }
            '+' | '-' | '*' | '/' => {
                tokens.push(Token::Operator(chars.next().unwrap()));
            }
            _ => { chars.next(); }
        }
    }
    tokens.push(Token::Eof);
    tokens
}''',

"go": '''// HTTP server with middleware, goroutines, channels
package main

import (
    "context"
    "fmt"
    "log"
    "net/http"
    "sync"
    "time"
)

type Middleware func(http.Handler) http.Handler

func Logger(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        start := time.Now()
        next.ServeHTTP(w, r)
        log.Printf("%s %s %v", r.Method, r.URL.Path, time.Since(start))
    })
}

func RateLimit(rps int) Middleware {
    var mu sync.Mutex
    tokens := rps
    go func() {
        ticker := time.NewTicker(time.Second / time.Duration(rps))
        defer ticker.Stop()
        for range ticker.C {
            mu.Lock()
            if tokens < rps { tokens++ }
            mu.Unlock()
        }
    }()
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            mu.Lock()
            if tokens <= 0 {
                mu.Unlock()
                http.Error(w, "rate limited", http.StatusTooManyRequests)
                return
            }
            tokens--
            mu.Unlock()
            next.ServeHTTP(w, r)
        })
    }
}''',

"c": '''/* Binary search tree with insert, search, free */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct Node {
    int key;
    char value[64];
    struct Node *left, *right;
} Node;

Node* create_node(int key, const char* value) {
    Node* node = (Node*)malloc(sizeof(Node));
    node->key = key;
    strncpy(node->value, value, 63);
    node->value[63] = '\\0';
    node->left = node->right = NULL;
    return node;
}

Node* insert(Node* root, int key, const char* value) {
    if (!root) return create_node(key, value);
    if (key < root->key)
        root->left = insert(root->left, key, value);
    else if (key > root->key)
        root->right = insert(root->right, key, value);
    else
        strncpy(root->value, value, 63);
    return root;
}

const char* search(Node* root, int key) {
    if (!root) return NULL;
    if (key == root->key) return root->value;
    return key < root->key ? search(root->left, key) : search(root->right, key);
}

void free_tree(Node* root) {
    if (!root) return;
    free_tree(root->left);
    free_tree(root->right);
    free(root);
}''',

"cpp": '''// RAII smart pointers, templates, STL algorithms
#include <algorithm>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

template <typename T>
class ThreadSafeQueue {
    std::vector<T> data_;
    mutable std::mutex mutex_;

public:
    void push(T value) {
        std::lock_guard<std::mutex> lock(mutex_);
        data_.push_back(std::move(value));
    }

    std::optional<T> pop() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (data_.empty()) return std::nullopt;
        T val = std::move(data_.back());
        data_.pop_back();
        return val;
    }

    [[nodiscard]] size_t size() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return data_.size();
    }

    template <typename Pred>
    std::vector<T> filter(Pred predicate) const {
        std::lock_guard<std::mutex> lock(mutex_);
        std::vector<T> result;
        std::copy_if(data_.begin(), data_.end(),
                     std::back_inserter(result), predicate);
        return result;
    }
};''',

"java": '''// Generics, streams, records, sealed interfaces
import java.util.*;
import java.util.stream.*;

public sealed interface Shape permits Circle, Rectangle, Triangle {
    double area();
    double perimeter();
}

public record Circle(double radius) implements Shape {
    @Override public double area() { return Math.PI * radius * radius; }
    @Override public double perimeter() { return 2 * Math.PI * radius; }
}

public record Rectangle(double width, double height) implements Shape {
    @Override public double area() { return width * height; }
    @Override public double perimeter() { return 2 * (width + height); }
}

public record Triangle(double a, double b, double c) implements Shape {
    @Override
    public double area() {
        double s = (a + b + c) / 2;
        return Math.sqrt(s * (s - a) * (s - b) * (s - c));
    }
    @Override public double perimeter() { return a + b + c; }
}''',

"kotlin": '''// Data class, sealed class, coroutines, extension functions
import kotlinx.coroutines.*

sealed class Result<out T> {
    data class Success<T>(val data: T) : Result<T>()
    data class Error(val message: String, val cause: Throwable? = null) : Result<Nothing>()
    data object Loading : Result<Nothing>()
}

data class User(val id: Long, val name: String, val email: String)

fun String.isValidEmail(): Boolean =
    matches(Regex("^[A-Za-z0-9+_.-]+@[A-Za-z0-9.-]+$"))

suspend fun fetchUser(id: Long): Result<User> = withContext(Dispatchers.IO) {
    try {
        delay(100) // simulate network
        Result.Success(User(id, "User $id", "user$id@example.com"))
    } catch (e: Exception) {
        Result.Error("Failed to fetch user $id", e)
    }
}

fun main() = runBlocking {
    val users = (1L..5L).map { async { fetchUser(it) } }.awaitAll()
    users.filterIsInstance<Result.Success<User>>()
        .forEach { println("${it.data.name}: ${it.data.email}") }
}''',

"swift": '''// Protocol-oriented, async/await, property wrappers
import Foundation

@propertyWrapper
struct Clamped<Value: Comparable> {
    var wrappedValue: Value {
        didSet { wrappedValue = min(max(wrappedValue, range.lowerBound), range.upperBound) }
    }
    let range: ClosedRange<Value>

    init(wrappedValue: Value, _ range: ClosedRange<Value>) {
        self.range = range
        self.wrappedValue = min(max(wrappedValue, range.lowerBound), range.upperBound)
    }
}

protocol Fetchable: Decodable, Sendable {
    static var endpoint: String { get }
}

actor NetworkManager {
    private let session: URLSession
    private var cache: [String: Data] = [:]

    init(session: URLSession = .shared) { self.session = session }

    func fetch<T: Fetchable>(_ type: T.Type) async throws -> T {
        if let cached = cache[T.endpoint] {
            return try JSONDecoder().decode(T.self, from: cached)
        }
        let url = URL(string: "https://api.example.com/\\(T.endpoint)")!
        let (data, _) = try await session.data(from: url)
        cache[T.endpoint] = data
        return try JSONDecoder().decode(T.self, from: data)
    }
}''',

"ruby": '''# Metaprogramming, blocks, modules, DSL
module Validatable
  def self.included(base)
    base.extend(ClassMethods)
    base.instance_variable_set(:@validations, [])
  end

  module ClassMethods
    def validates(field, **options)
      @validations << { field: field, **options }
    end

    def validations = @validations
  end

  def valid?
    self.class.validations.all? do |v|
      value = send(v[:field])
      case
      when v[:presence] then !value.nil? && !value.to_s.empty?
      when v[:length] then value.to_s.length.between?(*v[:length].minmax)
      when v[:format] then value.to_s.match?(v[:format])
      else true
      end
    end
  end
end

class User
  include Validatable
  attr_accessor :name, :email, :age

  validates :name, presence: true, length: 2..50
  validates :email, presence: true, format: /\\A[\\w+.-]+@[\\w.-]+\\z/
  validates :age, presence: true
end''',

"php": '''<?php
// Type hints, attributes, enums, fibers
enum Status: string {
    case Active = 'active';
    case Inactive = 'inactive';
    case Pending = 'pending';
}

#[Attribute(Attribute::TARGET_METHOD)]
class Route {
    public function __construct(
        public readonly string $method,
        public readonly string $path,
    ) {}
}

class UserController {
    private array $users = [];

    #[Route('GET', '/users')]
    public function index(): array {
        return array_filter($this->users, fn(User $u) => $u->status === Status::Active);
    }

    #[Route('POST', '/users')]
    public function create(string $name, string $email): User {
        $user = new User(
            id: count($this->users) + 1,
            name: $name,
            email: $email,
            status: Status::Pending,
        );
        $this->users[] = $user;
        return $user;
    }
}''',

"sql": '''-- Complex queries: CTEs, window functions, JSON
WITH monthly_revenue AS (
    SELECT
        DATE_TRUNC('month', o.created_at) AS month,
        p.category,
        SUM(oi.quantity * oi.unit_price) AS revenue,
        COUNT(DISTINCT o.customer_id) AS unique_customers
    FROM orders o
    JOIN order_items oi ON o.id = oi.order_id
    JOIN products p ON oi.product_id = p.id
    WHERE o.status = 'completed'
      AND o.created_at >= NOW() - INTERVAL '12 months'
    GROUP BY 1, 2
),
ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY month ORDER BY revenue DESC) AS rank,
        LAG(revenue) OVER (PARTITION BY category ORDER BY month) AS prev_revenue,
        revenue - LAG(revenue) OVER (PARTITION BY category ORDER BY month) AS growth
    FROM monthly_revenue
)
SELECT month, category, revenue, unique_customers, rank,
       ROUND(growth / NULLIF(prev_revenue, 0) * 100, 1) AS growth_pct
FROM ranked
WHERE rank <= 5
ORDER BY month DESC, rank;''',

"html": '''<!-- Semantic HTML5 with ARIA, forms, media -->
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Dashboard — Kern Editor</title>
    <link rel="stylesheet" href="/styles/main.css">
</head>
<body>
    <header role="banner">
        <nav aria-label="Main navigation">
            <ul>
                <li><a href="/" aria-current="page">Home</a></li>
                <li><a href="/docs">Docs</a></li>
            </ul>
        </nav>
    </header>
    <main id="content" role="main">
        <section aria-labelledby="stats-heading">
            <h2 id="stats-heading">Statistics</h2>
            <dl>
                <dt>Total Users</dt>
                <dd>12,847</dd>
            </dl>
        </section>
        <form action="/api/submit" method="POST">
            <label for="email">Email</label>
            <input type="email" id="email" name="email" required
                   placeholder="user@example.com" autocomplete="email">
            <button type="submit">Subscribe</button>
        </form>
    </main>
</body>
</html>''',

"css": '''/* Grid layout, custom properties, animations, container queries */
:root {
  --color-primary: #007aff;
  --color-surface: #f5f5f7;
  --spacing-unit: 8px;
  --font-sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
  --shadow-card: 0 2px 8px rgba(0, 0, 0, 0.08);
}

@container (min-width: 600px) {
  .card-grid {
    grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
  }
}

.card {
  background: var(--color-surface);
  border-radius: calc(var(--spacing-unit) * 2);
  padding: calc(var(--spacing-unit) * 3);
  box-shadow: var(--shadow-card);
  transition: transform 0.2s ease, box-shadow 0.2s ease;

  &:hover {
    transform: translateY(-2px);
    box-shadow: 0 4px 16px rgba(0, 0, 0, 0.12);
  }

  & .title { font: 600 1.25rem var(--font-sans); }
  & .badge { background: var(--color-primary); color: white; }
}

@keyframes fadeSlideIn {
  from { opacity: 0; transform: translateY(20px); }
  to { opacity: 1; transform: translateY(0); }
}''',

"scss": '''// Mixins, functions, maps, nesting, loops
$breakpoints: (
  sm: 640px,
  md: 768px,
  lg: 1024px,
  xl: 1280px,
);

@mixin respond-to($name) {
  @if map-has-key($breakpoints, $name) {
    @media (min-width: map-get($breakpoints, $name)) { @content; }
  } @else {
    @warn "Unknown breakpoint: #{$name}";
  }
}

@function spacing($multiplier: 1) {
  @return $multiplier * 8px;
}

.sidebar {
  width: 100%;
  padding: spacing(2);

  @include respond-to(md) { width: 280px; }
  @include respond-to(lg) { width: 320px; }

  &__nav {
    list-style: none;
    @each $state, $color in (active: #007aff, hover: #e3f2ff, disabled: #ccc) {
      &--#{$state} { background: $color; }
    }
  }
}''',

"yaml": '''# Kubernetes deployment with multiple resources
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kern-api
  namespace: production
  labels:
    app: kern
    tier: backend
    version: v2.1.0
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: kern
  template:
    metadata:
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9090"
    spec:
      containers:
        - name: api
          image: ghcr.io/kern/api:2.1.0
          ports:
            - containerPort: 8080
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: db-credentials
                  key: url
          resources:
            requests: { cpu: "250m", memory: "512Mi" }
            limits: { cpu: "1000m", memory: "1Gi" }
          livenessProbe:
            httpGet: { path: /health, port: 8080 }
            initialDelaySeconds: 15''',

"json": '''{
  "name": "kern-editor",
  "version": "1.0.0",
  "description": "A native macOS WYSIWYG markdown editor",
  "engines": { "node": ">=20.0.0" },
  "scripts": {
    "build": "vite build",
    "dev": "vite --port 3000",
    "test": "vitest run",
    "lint": "eslint src/ --ext .ts,.tsx"
  },
  "dependencies": {
    "@milkdown/crepe": "7.18.0",
    "mermaid": "^11.0.0"
  },
  "devDependencies": {
    "typescript": "^5.4.0",
    "vite": "^6.0.0",
    "vitest": "^2.0.0",
    "eslint": "^9.0.0"
  },
  "repository": {
    "type": "git",
    "url": "https://github.com/example/kern-editor"
  },
  "license": "MIT"
}''',

"toml": '''# Rust Cargo.toml with workspace
[workspace]
members = ["core", "cli", "web"]
resolver = "2"

[workspace.package]
version = "0.5.0"
edition = "2021"
authors = ["Kern Team <team@kern.dev>"]
license = "MIT OR Apache-2.0"
rust-version = "1.75"

[workspace.dependencies]
tokio = { version = "1.35", features = ["full"] }
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
tracing = "0.1"
anyhow = "1.0"

[package]
name = "kern-core"
version.workspace = true
edition.workspace = true

[dependencies]
tokio = { workspace = true }
serde = { workspace = true }

[[bin]]
name = "kern"
path = "src/main.rs"''',

"xml": '''<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
                             http://maven.apache.org/xsd/maven-4.0.0.xsd">
    <modelVersion>4.0.0</modelVersion>
    <groupId>dev.kern</groupId>
    <artifactId>kern-server</artifactId>
    <version>1.0-SNAPSHOT</version>
    <packaging>jar</packaging>

    <properties>
        <java.version>21</java.version>
        <spring.version>3.2.0</spring.version>
    </properties>

    <dependencies>
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-starter-web</artifactId>
            <version>${spring.version}</version>
        </dependency>
    </dependencies>
</project>''',

"bash": '''#!/bin/bash
# Deployment script with error handling, colors, logging
set -euo pipefail

readonly RED='\\033[0;31m'
readonly GREEN='\\033[0;32m'
readonly YELLOW='\\033[1;33m'
readonly NC='\\033[0m'

log() { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

readonly APP_NAME="${1:?Usage: $0 <app-name> <environment>}"
readonly ENVIRONMENT="${2:?Usage: $0 <app-name> <environment>}"

deploy() {
    log "Deploying $APP_NAME to $ENVIRONMENT..."

    local image="ghcr.io/kern/${APP_NAME}:${GIT_SHA:-$(git rev-parse --short HEAD)}"
    log "Image: $image"

    if ! docker pull "$image" 2>/dev/null; then
        error "Failed to pull image: $image"
    fi

    local old_container
    old_container=$(docker ps -q --filter "name=${APP_NAME}" || true)
    if [[ -n "$old_container" ]]; then
        warn "Stopping old container: $old_container"
        docker stop "$old_container" && docker rm "$old_container"
    fi

    docker run -d --name "$APP_NAME" --restart unless-stopped \\
        -p 8080:8080 -e "ENV=$ENVIRONMENT" "$image"

    log "Deployed successfully!"
}

deploy''',

"powershell": '''# System administration with error handling
param(
    [Parameter(Mandatory=$true)]
    [string]$ServerName,

    [ValidateSet("Start", "Stop", "Restart")]
    [string]$Action = "Restart",

    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp][$Level] $Message" -ForegroundColor $(
        switch ($Level) {
            "ERROR" { "Red" }
            "WARN"  { "Yellow" }
            default { "Green" }
        }
    )
}

try {
    Write-Log "Performing $Action on $ServerName..."
    $service = Get-Service -ComputerName $ServerName -Name "KernService"

    switch ($Action) {
        "Stop"    { $service | Stop-Service -Force }
        "Start"   { $service | Start-Service }
        "Restart" { $service | Restart-Service -Force }
    }

    Write-Log "$Action completed successfully on $ServerName"
} catch {
    Write-Log "Failed: $_" -Level "ERROR"
    throw
}''',

"lua": '''-- Game entity system with metatables
local Entity = {}
Entity.__index = Entity

function Entity.new(name, x, y)
    local self = setmetatable({}, Entity)
    self.name = name
    self.x = x or 0
    self.y = y or 0
    self.components = {}
    self.active = true
    return self
end

function Entity:addComponent(name, component)
    self.components[name] = component
    component.entity = self
    if component.init then component:init() end
    return self
end

function Entity:update(dt)
    if not self.active then return end
    for _, comp in pairs(self.components) do
        if comp.update then comp:update(dt) end
    end
end

-- Physics component
local Physics = {}
Physics.__index = Physics

function Physics.new(mass, friction)
    return setmetatable({
        mass = mass or 1.0,
        friction = friction or 0.98,
        vx = 0, vy = 0,
    }, Physics)
end

function Physics:update(dt)
    self.entity.x = self.entity.x + self.vx * dt
    self.entity.y = self.entity.y + self.vy * dt
    self.vx = self.vx * self.friction
    self.vy = self.vy * self.friction
end''',

"haskell": '''-- Type classes, monads, algebraic data types
module Parser where

import Control.Monad (void)
import Data.Char (isAlpha, isDigit, isSpace)

data Expr
    = Lit Double
    | Var String
    | BinOp Op Expr Expr
    | UnaryOp Op Expr
    | FunCall String [Expr]
    deriving (Show, Eq)

data Op = Add | Sub | Mul | Div | Pow
    deriving (Show, Eq)

newtype Parser a = Parser { runParser :: String -> Maybe (a, String) }

instance Functor Parser where
    fmap f (Parser p) = Parser $ \\s -> do
        (a, rest) <- p s
        Just (f a, rest)

instance Applicative Parser where
    pure x = Parser $ \\s -> Just (x, s)
    (Parser pf) <*> (Parser pa) = Parser $ \\s -> do
        (f, rest1) <- pf s
        (a, rest2) <- pa rest1
        Just (f a, rest2)

instance Monad Parser where
    (Parser pa) >>= f = Parser $ \\s -> do
        (a, rest) <- pa s
        runParser (f a) rest

satisfy :: (Char -> Bool) -> Parser Char
satisfy pred = Parser $ \\case
    (c:cs) | pred c -> Just (c, cs)
    _ -> Nothing''',

"elixir": '''# GenServer, pattern matching, pipes, protocols
defmodule Cache do
  use GenServer

  @default_ttl :timer.minutes(5)

  # Client API
  def start_link(opts \\\\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  def get(key), do: GenServer.call(__MODULE__, {:get, key})
  def put(key, value, ttl \\\\ @default_ttl), do: GenServer.cast(__MODULE__, {:put, key, value, ttl})
  def delete(key), do: GenServer.cast(__MODULE__, {:delete, key})

  # Server callbacks
  @impl true
  def init(_) do
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    case Map.get(state, key) do
      {value, expires_at} when expires_at > System.monotonic_time(:millisecond) ->
        {:reply, {:ok, value}, state}
      _ ->
        {:reply, :error, Map.delete(state, key)}
    end
  end

  @impl true
  def handle_cast({:put, key, value, ttl}, state) do
    expires_at = System.monotonic_time(:millisecond) + ttl
    {:noreply, Map.put(state, key, {value, expires_at})}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @default_ttl)
  end
end''',

"clojure": ''';;; Ring handler with middleware composition
(ns kern.api.handler
  (:require [clojure.string :as str]
            [ring.middleware.json :refer [wrap-json-response wrap-json-body]]
            [ring.middleware.cors :refer [wrap-cors]]
            [ring.util.response :as resp]))

(defn wrap-logging [handler]
  (fn [request]
    (let [start  (System/currentTimeMillis)
          result (handler request)
          elapsed (- (System/currentTimeMillis) start)]
      (println (format "%s %s %dms" (:request-method request) (:uri request) elapsed))
      result)))

(defmulti handle-route (fn [req] [(:request-method req) (:uri req)]))

(defmethod handle-route [:get "/api/users"] [_]
  (resp/response {:users [{:id 1 :name "Alice"} {:id 2 :name "Bob"}]}))

(defmethod handle-route [:post "/api/users"] [{:keys [body]}]
  (let [{:keys [name email]} body]
    (if (and name email)
      (resp/created "/api/users/3" {:id 3 :name name :email email})
      (resp/bad-request {:error "name and email required"}))))

(defmethod handle-route :default [req]
  (resp/not-found {:error "not found"}))

(def app
  (-> handle-route
      wrap-json-body
      wrap-json-response
      wrap-logging
      (wrap-cors :access-control-allow-origin [#".*"])))''',

"scala": '''// Case classes, for-comprehension, implicits, futures
import scala.concurrent.{Future, ExecutionContext}
import scala.util.{Success, Failure}

case class User(id: Long, name: String, email: String)
case class Order(id: Long, userId: Long, total: BigDecimal, items: List[OrderItem])
case class OrderItem(productId: Long, name: String, qty: Int, price: BigDecimal)

trait UserRepository:
  def findById(id: Long)(using ec: ExecutionContext): Future[Option[User]]
  def findAll(using ec: ExecutionContext): Future[List[User]]

trait OrderRepository:
  def findByUserId(userId: Long)(using ec: ExecutionContext): Future[List[Order]]

class OrderService(users: UserRepository, orders: OrderRepository):
  def getUserOrders(userId: Long)(using ec: ExecutionContext): Future[Option[(User, List[Order])]] =
    for
      maybeUser   <- users.findById(userId)
      userOrders  <- orders.findByUserId(userId)
    yield maybeUser.map(user => (user, userOrders))

  def totalSpent(userId: Long)(using ec: ExecutionContext): Future[BigDecimal] =
    orders.findByUserId(userId).map(_.map(_.total).sum)''',

"r": '''# Statistical analysis with tidyverse
library(tidyverse)
library(ggplot2)

# Load and clean data
raw_data <- read_csv("experiments.csv") %>%
  filter(!is.na(value), group %in% c("control", "treatment")) %>%
  mutate(
    log_value = log10(value + 1),
    group = factor(group, levels = c("control", "treatment")),
    date = as.Date(timestamp)
  )

# Summary statistics
summary_stats <- raw_data %>%
  group_by(group) %>%
  summarise(
    n = n(),
    mean = mean(value),
    sd = sd(value),
    median = median(value),
    ci_lower = mean - qt(0.975, n() - 1) * sd / sqrt(n()),
    ci_upper = mean + qt(0.975, n() - 1) * sd / sqrt(n()),
    .groups = "drop"
  )

# Two-sample t-test
test_result <- t.test(
  value ~ group,
  data = raw_data,
  alternative = "two.sided",
  var.equal = FALSE
)

cat(sprintf("t = %.3f, p = %.4f\\n", test_result$statistic, test_result$p.value))''',

"perl": '''#!/usr/bin/perl
# Log parser with regex, hashes, file I/O
use strict;
use warnings;
use File::Find;
use Getopt::Long;

my ($log_dir, $pattern, $output);
GetOptions(
    'dir=s'     => \\$log_dir,
    'pattern=s' => \\$pattern,
    'output=s'  => \\$output,
) or die "Usage: $0 --dir <path> --pattern <regex> [--output <file>]\\n";

$log_dir //= '/var/log';
$pattern //= 'ERROR|WARN|FATAL';

my %stats;
my @matches;

find(sub {
    return unless -f && /\\.log$/;
    open my $fh, '<', $_ or warn "Cannot open $_: $!" and return;
    while (my $line = <$fh>) {
        chomp $line;
        if ($line =~ /($pattern)/i) {
            my $level = uc($1);
            $stats{$level}++;
            push @matches, { file => $File::Find::name, line => $., text => $line };
        }
    }
    close $fh;
}, $log_dir);

printf "%-10s %d\\n", $_, $stats{$_} for sort keys %stats;
printf "Total matches: %d\\n", scalar @matches;''',

"dart": '''// Null safety, streams, isolates, freezed
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

sealed class AppState {
  const AppState();
}
class Loading extends AppState { const Loading(); }
class Loaded extends AppState {
  final List<Todo> todos;
  const Loaded(this.todos);
}
class Error extends AppState {
  final String message;
  const Error(this.message);
}

class Todo {
  final int id;
  final String title;
  final bool completed;

  const Todo({required this.id, required this.title, this.completed = false});

  Todo copyWith({String? title, bool? completed}) =>
    Todo(id: id, title: title ?? this.title, completed: completed ?? this.completed);

  factory Todo.fromJson(Map<String, dynamic> json) => Todo(
    id: json['id'] as int,
    title: json['title'] as String,
    completed: json['completed'] as bool? ?? false,
  );
}

class TodoBloc {
  final _stateController = StreamController<AppState>.broadcast();
  Stream<AppState> get state => _stateController.stream;

  Future<void> loadTodos() async {
    _stateController.add(const Loading());
    try {
      final todos = await Isolate.run(() => _parseTodos(mockData));
      _stateController.add(Loaded(todos));
    } catch (e) {
      _stateController.add(Error(e.toString()));
    }
  }
}''',

"zig": '''// Allocators, error unions, comptime, SIMD
const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

pub fn Matrix(comptime T: type) type {
    return struct {
        data: []T,
        rows: usize,
        cols: usize,
        allocator: Allocator,

        const Self = @This();

        pub fn init(allocator: Allocator, rows: usize, cols: usize) !Self {
            const data = try allocator.alloc(T, rows * cols);
            @memset(data, 0);
            return .{ .data = data, .rows = rows, .cols = cols, .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.data);
        }

        pub fn get(self: Self, row: usize, col: usize) T {
            return self.data[row * self.cols + col];
        }

        pub fn set(self: *Self, row: usize, col: usize, val: T) void {
            self.data[row * self.cols + col] = val;
        }

        pub fn multiply(self: Self, other: Self, allocator: Allocator) !Self {
            std.debug.assert(self.cols == other.rows);
            var result = try Self.init(allocator, self.rows, other.cols);
            for (0..self.rows) |i| {
                for (0..other.cols) |j| {
                    var sum: T = 0;
                    for (0..self.cols) |k| {
                        sum += self.get(i, k) * other.get(k, j);
                    }
                    result.set(i, j, sum);
                }
            }
            return result;
        }
    };
}''',

"ocaml": '''(* Algebraic types, functors, pattern matching *)
module type ORDERED = sig
  type t
  val compare : t -> t -> int
end

module BinaryTree (Ord : ORDERED) = struct
  type 'a tree =
    | Empty
    | Node of 'a tree * Ord.t * 'a * 'a tree

  let rec insert key value = function
    | Empty -> Node (Empty, key, value, Empty)
    | Node (left, k, v, right) ->
      let c = Ord.compare key k in
      if c < 0 then Node (insert key value left, k, v, right)
      else if c > 0 then Node (left, k, v, insert key value right)
      else Node (left, key, value, right)

  let rec find key = function
    | Empty -> None
    | Node (left, k, v, right) ->
      let c = Ord.compare key k in
      if c = 0 then Some v
      else if c < 0 then find key left
      else find key right

  let rec fold f acc = function
    | Empty -> acc
    | Node (left, k, v, right) ->
      let acc = fold f acc left in
      let acc = f acc k v in
      fold f acc right

  let to_list tree = List.rev (fold (fun acc k v -> (k, v) :: acc) [] tree)
end''',

"graphql": '''# Schema with types, queries, mutations, subscriptions
type User {
  id: ID!
  name: String!
  email: String!
  avatar: String
  posts(first: Int = 10, after: String): PostConnection!
  followers: [User!]!
  createdAt: DateTime!
}

type Post {
  id: ID!
  title: String!
  content: String!
  author: User!
  tags: [Tag!]!
  comments(first: Int = 20): [Comment!]!
  likeCount: Int!
  publishedAt: DateTime
}

type PostConnection {
  edges: [PostEdge!]!
  pageInfo: PageInfo!
  totalCount: Int!
}

input CreatePostInput {
  title: String!
  content: String!
  tagIds: [ID!]
  publishNow: Boolean = false
}

type Query {
  user(id: ID!): User
  posts(filter: PostFilter, sort: PostSort): PostConnection!
  search(query: String!, type: SearchType): [SearchResult!]!
}

type Mutation {
  createPost(input: CreatePostInput!): Post!
  updatePost(id: ID!, input: UpdatePostInput!): Post!
  deletePost(id: ID!): Boolean!
  toggleLike(postId: ID!): Post!
}

type Subscription {
  postCreated: Post!
  commentAdded(postId: ID!): Comment!
}''',

"protobuf": '''// gRPC service definition with nested messages
syntax = "proto3";

package kern.api.v1;

option go_package = "github.com/kern/api/v1;apiv1";
option java_multiple_files = true;

import "google/protobuf/timestamp.proto";
import "google/protobuf/field_mask.proto";

message Document {
  string id = 1;
  string title = 2;
  string content = 3;
  DocumentStatus status = 4;
  google.protobuf.Timestamp created_at = 5;
  google.protobuf.Timestamp updated_at = 6;
  map<string, string> metadata = 7;

  enum DocumentStatus {
    DOCUMENT_STATUS_UNSPECIFIED = 0;
    DRAFT = 1;
    PUBLISHED = 2;
    ARCHIVED = 3;
  }
}

service DocumentService {
  rpc CreateDocument(CreateDocumentRequest) returns (Document);
  rpc GetDocument(GetDocumentRequest) returns (Document);
  rpc ListDocuments(ListDocumentsRequest) returns (ListDocumentsResponse);
  rpc UpdateDocument(UpdateDocumentRequest) returns (Document);
  rpc DeleteDocument(DeleteDocumentRequest) returns (google.protobuf.Empty);
  rpc WatchDocuments(WatchDocumentsRequest) returns (stream DocumentEvent);
}

message ListDocumentsRequest {
  int32 page_size = 1;
  string page_token = 2;
  string filter = 3;
  string order_by = 4;
}''',

"dockerfile": '''# Multi-stage build with security best practices
FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --production=false

FROM node:20-alpine AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npm run build && npm prune --production

FROM gcr.io/distroless/nodejs20-debian12 AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=8080

COPY --from=builder --chown=nonroot:nonroot /app/dist ./dist
COPY --from=builder --chown=nonroot:nonroot /app/node_modules ./node_modules
COPY --from=builder --chown=nonroot:nonroot /app/package.json ./

USER nonroot:nonroot
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --retries=3 \\
  CMD ["node", "-e", "fetch('http://localhost:8080/health').then(r => process.exit(r.ok ? 0 : 1))"]

ENTRYPOINT ["node", "dist/server.js"]''',

"makefile": '''# Project build system with phony targets, variables, functions
CC := clang
CFLAGS := -Wall -Wextra -Werror -std=c17 -O2
LDFLAGS := -lpthread -lm
SRC_DIR := src
BUILD_DIR := build
BIN := $(BUILD_DIR)/kern

SOURCES := $(wildcard $(SRC_DIR)/*.c)
OBJECTS := $(SOURCES:$(SRC_DIR)/%.c=$(BUILD_DIR)/%.o)
DEPS := $(OBJECTS:.o=.d)

.PHONY: all clean test install

all: $(BIN)

$(BIN): $(OBJECTS) | $(BUILD_DIR)
\t$(CC) $(OBJECTS) -o $@ $(LDFLAGS)
\t@echo "Built $@"

$(BUILD_DIR)/%.o: $(SRC_DIR)/%.c | $(BUILD_DIR)
\t$(CC) $(CFLAGS) -MMD -MP -c $< -o $@

$(BUILD_DIR):
\t@mkdir -p $@

clean:
\trm -rf $(BUILD_DIR)

test: $(BIN)
\t@./tests/run_tests.sh

-include $(DEPS)''',

"terraform": '''# AWS infrastructure with modules and data sources
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    bucket = "kern-terraform-state"
    key    = "prod/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

variable "environment" {
  type    = string
  default = "production"
}

resource "aws_ecs_service" "api" {
  name            = "kern-api-${var.environment}"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = 3
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.api.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 8080
  }

  lifecycle {
    ignore_changes = [desired_count]
  }
}

output "api_endpoint" {
  value = "https://${aws_lb.main.dns_name}/api"
}''',
}

for lang, code in code_blocks.items():
    w(f"### {lang}")
    w()
    w(f"```{lang}")
    w(code)
    w("```")
    w()

# Write to file in parts
with open(OUT, 'w') as f:
    f.write('\n'.join(lines))

print(f"Part 1 written: {len(lines)} lines")
