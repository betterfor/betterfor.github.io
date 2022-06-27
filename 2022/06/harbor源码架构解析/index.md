# Harbor源码架构解析


Harbor源码分析之Core组件

版本：v1.10.11

![harbor_arch](https://cdn.jsdelivr.net/gh/goharbor/harbor@v1.10.11/docs/img/harbor-arch.png)

## 一、core目录架构

```sh
$ tree -L 1
.
├── api
├── auth
├── config
├── controllers
├── filter
├── label
├── main.go
├── middlewares
├── notifier
├── promgr
├── router.go
├── service
├── systeminfo
├── utils
└── views
```

如果对页面比较熟悉的话，大致可以猜到这些目录的主要功能是什么。

- api：api接口
- controller：api接口，关于登入登出功能
- auth：权限认证
- config：配置相关
- filter：过滤器
- label：项目资源的label管理
- middlewares：中间件
- notifier：消息通知
- promgr：项目管理
- service：第三方api调用
- systeminfo：系统信息，主要是镜像存储相关
- utils：工具类
- views：页面

## 二、core组件

core文件夹是harbor的核心组件，根目录下有`main.go`和`router.go`两个文件。

`main.go`用来初始化后端项目，`router.go`对请求路由的处理。

我们先从`main.go`开始。

### 1、初始化session、模板

```go
beego.BConfig.WebConfig.Session.SessionOn = true
beego.BConfig.WebConfig.Session.SessionName = config.SessionCookieName

redisURL := os.Getenv("_REDIS_URL")
if len(redisURL) > 0 {
	gob.Register(models.User{})
	beego.BConfig.WebConfig.Session.SessionProvider = "redis"
	beego.BConfig.WebConfig.Session.SessionProviderConfig = redisURL
}
beego.AddTemplateExt("htm")
```

### 2、初始化配置

```go
log.Info("initializing configurations...")
if err := config.Init(); err != nil {
	log.Fatalf("failed to initialize configurations: %v", err)
}
log.Info("configurations initialization completed")
```

### 3、初始化accessFilter

为多个服务初始化accessFilter

```go
token.InitCreators()
```

主要就是对`repository`和`registry`的一些操作进行过滤处理，根据角色进行一些权限约束

### 4、初始化数据库连接

注册数据库，从数据库读取配置文件，然后覆盖本地配置

```go
database, err := config.Database()
if err != nil {
	log.Fatalf("failed to get database configuration: %v", err)
}
if err := dao.InitAndUpgradeDatabase(database); err != nil {
	log.Fatalf("failed to initialize database: %v", err)
}
if err := config.Load(); err != nil {
	log.Fatalf("failed to load config: %v", err)
}
```

### 5、初始化任务管理和调度器

```go
// init the jobservice client
job.Init()
// init the scheduler
scheduler.Init()
```

### 6、从配置中获取到管理员密码，更新到数据库中

```go
password, err := config.InitialAdminPassword()
if err != nil {
	log.Fatalf("failed to get admin's initial password: %v", err)
}
if err := updateInitPassword(adminUserID, password); err != nil {
	log.Error(err)
}
```

### 7、初始化api

```go
// Init API handler
if err := api.Init(); err != nil {
	log.Fatalf("Failed to initialize API handlers with error: %s", err.Error())
}
```

### 8、如果配置镜像扫描clair，则初始化相关数据库及触发定时扫描所有镜像的事件

```go
if config.WithClair() {
	clairDB, err := config.ClairDB()
	if err != nil {
		log.Fatalf("failed to load clair database information: %v", err)
	}
	if err := dao.InitClairDB(clairDB); err != nil {
		log.Fatalf("failed to initialize clair database: %v", err)
	}

	reg := &scanner.Registration{
		Name:            "Clair",
		Description:     "The clair scanner adapter",
		URL:             config.ClairAdapterEndpoint(),
		UseInternalAddr: true,
		Immutable:       true,
	}

	if err := scan.EnsureScanner(reg, true); err != nil {
		log.Fatalf("failed to initialize clair scanner: %v", err)
	}
} else {
	if err := scan.RemoveImmutableScanners(); err != nil {
		log.Warningf("failed to remove immutable scanners: %v", err)
	}
}
```

### 9、注册优雅关闭

```go
closing := make(chan struct{})
done := make(chan struct{})
go gracefulShutdown(closing, done)
```

### 10、初始化镜像复制功能

```go
if err := replication.Init(closing, done); err != nil {
	log.Fatalf("failed to init for replication: %v", err)
}
```

### 11、初始化消息事件通知

```go
log.Info("initializing notification...")
notification.Init()
// Initialize the event handlers for handling artifact cascade deletion
event.Init()
```

### 12、初始化过滤器，主要是安全相关的

```go
filter.Init()
beego.InsertFilter("/api/*", beego.BeforeStatic, filter.SessionCheck)
beego.InsertFilter("/*", beego.BeforeRouter, filter.SecurityFilter)
beego.InsertFilter("/*", beego.BeforeRouter, filter.ReadonlyFilter)
```

### 13、初始化请求路由，详见`router.go`

```go
initRouters()
```

### 14、将当前`Registry`里的镜像同步到数据库中

```go
syncRegistry := os.Getenv("SYNC_REGISTRY")
sync, err := strconv.ParseBool(syncRegistry)
if err != nil {
	log.Errorf("Failed to parse SYNC_REGISTRY: %v", err)
	// if err set it default to false
	sync = false
}
if sync {
	if err := api.SyncRegistry(config.GlobalProjectMgr); err != nil {
		log.Error(err)
	}
} else {
	log.Infof("Because SYNC_REGISTRY set false , no need to sync registry \n")
}
```

### 15、初始化反向代理

```go
log.Info("Init proxy")
if err := middlewares.Init(); err != nil {
	log.Fatalf("init proxy error, %v", err)
}
```

### 16、设置默认项目配额

```go
syncQuota := os.Getenv("SYNC_QUOTA")
doSyncQuota, err := strconv.ParseBool(syncQuota)
if err != nil {
	log.Errorf("Failed to parse SYNC_QUOTA: %v", err)
	doSyncQuota = true
}
if doSyncQuota {
	if err := quotaSync(); err != nil {
		log.Fatalf("quota migration error, %v", err)
	}
} else {
	log.Infof("Because SYNC_QUOTA set false , no need to sync quota \n")
}
```

### 17、启动beego服务

```go
beego.Run()
```

---

总的来说，这部分初始化的逻辑还是比较清晰的，想要去了解详情，可以到相应的模块，直接相关入口方法跟进去就可以了

## 三、common

common模块里放了一些其他模块公用的代码，比如一些工具函数、base结构体，DTO对象等

## 四、chartserver

主要实现一些操作chart资源相关的api接口

## 五、cmd

目前有数据库表迁移的工具

## 六、jobservice

jobservice主要提供一些执行任务的API接口，其它模块会调用它的接口调度定时任务。

### 1、读取配置信息

```go
// Get parameters
configPath := flag.String("c", "", "Specify the yaml config file path")
flag.Parse()

// Missing config file
if configPath == nil || utils.IsEmptyStr(*configPath) {
	flag.Usage()
	panic("no config file is specified")
}

// Load configurations
if err := config.DefaultConfig.Load(*configPath, true); err != nil {
	panic(fmt.Sprintf("load configurations error: %s\n", err))
}
```

### 2、初始化上下和日志

```go
vCtx := context.WithValue(context.Background(), utils.NodeID, utils.GenerateNodeID())
// Create the root context
ctx, cancel := context.WithCancel(vCtx)
defer cancel()

// Initialize logger
if err := logger.Init(ctx); err != nil {
	panic(err)
}

// Set job context initializer
runtime.JobService.SetJobContextInitializer(func(ctx context.Context) (job.Context, error) {
	secret := config.GetAuthSecret()
	if utils.IsEmptyStr(secret) {
		return nil, errors.New("empty auth secret")
	}
	coreURL := config.GetCoreURL()
	configURL := coreURL + common.CoreConfigPath
	cfgMgr := comcfg.NewRESTCfgManager(configURL, secret)
	jobCtx := impl.NewContext(ctx, cfgMgr)

	if err := jobCtx.Init(); err != nil {
		return nil, err
	}

	return jobCtx, nil
})
```

### 3、启动API

```go
if err := runtime.JobService.LoadAndRun(ctx, cancel); err != nil {
	logger.Fatal(err)
}
```

处理api的`LoadAndRun`实现如下：

1、初始化job的上下文

2、如果后台任务池是redis，则对redis进行一系列初始化设置

3、注册controller接口调用

4、启动http服务，注册优雅退出

在这里注册了路由

```go
func (br *BaseRouter) registerRoutes() {
	subRouter := br.router.PathPrefix(fmt.Sprintf("%s/%s", baseRoute, apiVersion)).Subrouter()

	subRouter.HandleFunc("/jobs", br.handler.HandleLaunchJobReq).Methods(http.MethodPost)
	subRouter.HandleFunc("/jobs", br.handler.HandleGetJobsReq).Methods(http.MethodGet)
	subRouter.HandleFunc("/jobs/{job_id}", br.handler.HandleGetJobReq).Methods(http.MethodGet)
	subRouter.HandleFunc("/jobs/{job_id}", br.handler.HandleJobActionReq).Methods(http.MethodPost)
	subRouter.HandleFunc("/jobs/{job_id}/log", br.handler.HandleJobLogReq).Methods(http.MethodGet)
	subRouter.HandleFunc("/stats", br.handler.HandleCheckStatusReq).Methods(http.MethodGet)
	subRouter.HandleFunc("/jobs/{job_id}/executions", br.handler.HandlePeriodicExecutions).Methods(http.MethodGet)
}
```

## 七、portal

portal是用AngularJS写的前端页面

## 八、replication

replication实现的是镜像复制的逻辑，支持从dockerhub、华为、googlegcr、awsecr、aliacr、jfrog、quayio、quayio、helmhub、gitlab复制镜像，如果有其他需求，可以参考这些代码实现定制化操作。

## 九、registryctl

registryctl主要提供一些操作`Registry`的API操作，可以直接针对接口了解

```go
func newRouter() http.Handler {
	r := mux.NewRouter()
	r.HandleFunc("/api/registry/gc", api.StartGC).Methods("POST")
	r.HandleFunc("/api/health", api.Health).Methods("GET")
	return r
}
```

## 十、总结

总体来看，harbor作为web项目的代码逻辑是比较清晰的，没有像kubernetes一样封装各种设计模式封装代码，作为一个golang项目，包括了web开发、docker镜像制作、Makefile编译脚本等一系列内容，作为新手老手都适合从中学习到不少东西。



