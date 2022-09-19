---
title: "Errgroup的实际应用"
date: 2021-07-05T10:00:08+08:00
draft: false

tags: ['sync','errgroup']
categories: ["go"]
comment: true
toc: true
autoCollapseToc: false
---

在标准库中有个[sync/errgroup](https://github.com/golang/sync/blob/master/errgroup/errgroup.go)，实现对多goroutine进行错误处理。

接下来我们看一下源码：

```go
type Group struct {
	cancel  func()
	wg      sync.WaitGroup
	errOnce sync.Once
	err     error
}

func WithCancel(ctx context.Context) (*Group, context.Context) {
	ctx, cancel := context.WithCancel(ctx)
	return &Group{cancel: cancel}, ctx
}

func (g *Group) Wait() error {
	g.wg.Wait()
	if g.cancel != nil {
		g.cancel()
	}
	return g.err
}

func (g *Group) Go(f func() error) {
	g.wg.Add(1)

	go func() {
		defer g.wg.Done()
		if err := f(); err != nil {
			g.errOnce.Do(func() {
				g.err = err
				if g.cancel != nil {
					g.cancel()
				}
			})
		}
	}()
}
```

很简单的实现，使用`sync.WaitGroup`做并发控制，用`sync.Once`做错误返回，使用`context`做上下文的处理。

## 例子一

```go
func main() {
	g := new(errgroup.Group)
	var urls = []string{
		"http://www.golang.org/",
		"https://golang2.eddycjy.com/",
		"https://eddycjy.com/",
	}
	for _, url := range urls {
		url := url
		g.Go(func() error {
			resp, err := http.Get(url)
			if err == nil {
				resp.Body.Close()
			}
			return err
		})
	}
	if err := g.Wait(); err == nil {
		fmt.Println("Successfully fetched all URLs.")
	} else {
		fmt.Printf("Errors: %+v", err)
	}
}
```

## 例子二

```go
func main() {
	g, ctx := errgroup.WithContext(context.Background())
	svr := http.NewServer()
	// http server
	g.Go(func() error {
		fmt.Println("http")
		go func() {
			<-ctx.Done()
			fmt.Println("http ctx done")
			svr.Shutdown(context.TODO())
		}()
		return svr.Start()
	})

	// signal
	g.Go(func() error {
		exitSignals := []os.Signal{os.Interrupt, syscall.SIGTERM, syscall.SIGQUIT, syscall.SIGINT} // SIGTERM is POSIX specific
		sig := make(chan os.Signal, len(exitSignals))
		signal.Notify(sig, exitSignals...)
		for {
			fmt.Println("signal")
			select {
			case <-ctx.Done():
				fmt.Println("signal ctx done")
				return ctx.Err()
			case <-sig:
				// do something
				return nil
			}
		}
	})

	// inject error
	g.Go(func() error {
		fmt.Println("inject")
		time.Sleep(time.Second)
		fmt.Println("inject finish")
		return errors.New("inject error")
	})

	err := g.Wait() // first error return
	fmt.Println(err)
}
```

