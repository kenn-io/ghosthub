from libghostty_bootstrap import BootstrapError, main


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BootstrapError as error:
        print(error)
        raise SystemExit(1) from error
